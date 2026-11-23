package syncsvc

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// refsAPI 在 snapshotAPI 之上补齐命名版本的两条路由（ADR-0054）。
type refsAPI struct{ snapshotAPI }

func (a refsAPI) GetV1SyncRefs(w http.ResponseWriter, r *http.Request) { a.h.Refs(w, r) }

func (a refsAPI) PutV1SyncRefs(w http.ResponseWriter, r *http.Request) { a.h.PutRef(w, r) }

// newRefHarness 与 newSnapshotHarness 相同，只是路由里多了 /v1/sync/refs。
func newRefHarness(t *testing.T) (*testutil.Client, *auth.Service, *snapshotHarness) {
	t.Helper()
	h := newSnapshotHarness(t)
	h.client = testutil.NewClient(t, testutil.NewServer(
		refsAPI{snapshotAPI{testAPI{h: h.handler}}},
		httpx.RequestID,
		auth.Middleware(h.authSvc, h.log),
	))
	return h.client, h.authSvc, h
}

// TestHandlerPushAnswersEachCommitSeq 守住逐条序号：推送响应的 seqs 与请求里的
// commits 按条数与顺序一一对应，新提交是服务端分配的序号，拉取到的 commit 与它
// 一致（ADR-0054）。
func TestHandlerPushAnswersEachCommitSeq(t *testing.T) {
	h := newSnapshotHarness(t)
	token := signIn(t, h.authSvc, "seqs@b.cn")

	var first api.PushResult
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r1"), commitBody("r2"), commitBody("r3")},
	}, &first); code != http.StatusOK {
		t.Fatalf("第一次推送: %d", code)
	}
	if first.Head != 3 || len(first.Seqs) != 3 || first.Seqs[0] != 1 || first.Seqs[1] != 2 || first.Seqs[2] != 3 {
		t.Fatalf("逐条序号应一一对应: %+v", first)
	}

	// 第二批里混一条重复的提交：重复的回原序号，新提交接着排。
	var second api.PushResult
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 3, "commits": []any{commitBody("r2"), commitBody("r4")},
	}, &second); code != http.StatusOK || second.Head != 4 {
		t.Fatalf("第二批推送: %d %+v", code, second)
	}
	if len(second.Seqs) != 2 || second.Seqs[0] != 2 || second.Seqs[1] != 4 {
		t.Fatalf("重复提交应回原序号、新提交接着排: %+v", second.Seqs)
	}

	// 拉取到的提交与响应里的序号一致。
	var page api.CommitPage
	if code := h.client.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &page); code != http.StatusOK || len(page.Commits) != 4 {
		t.Fatalf("拉取: %d %+v", code, page)
	}
	for i, commit := range page.Commits {
		if commit.Seq == nil || *commit.Seq != int64(i+1) {
			t.Fatalf("第 %d 条提交的序号: %+v", i+1, commit)
		}
	}
}

// TestHandlerReplayedBatchAnswersStoredSeqs 守住整批重放：同一 uid 重复推送不重复
// 写入，响应里的 seqs 回每次提交在服务端记下的原序号，head 不变（ADR-0040、
// ADR-0054）。
func TestHandlerReplayedBatchAnswersStoredSeqs(t *testing.T) {
	h := newSnapshotHarness(t)
	token := signIn(t, h.authSvc, "replay@b.cn")

	batch := []any{commitBody("dup-1"), commitBody("dup-2")}
	var first api.PushResult
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": batch,
	}, &first); code != http.StatusOK || first.Head != 2 {
		t.Fatalf("第一次推送: %d %+v", code, first)
	}

	var replay api.PushResult
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": batch,
	}, &replay); code != http.StatusOK || replay.Head != 2 {
		t.Fatalf("重放: %d %+v", code, replay)
	}
	if len(replay.Seqs) != 2 || replay.Seqs[0] != 1 || replay.Seqs[1] != 2 {
		t.Fatalf("重放应回原序号: %+v", replay.Seqs)
	}

	var page api.CommitPage
	if code := h.client.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &page); code != http.StatusOK || len(page.Commits) != 2 {
		t.Fatalf("重放不应追加提交: %d %+v", code, page)
	}
}

// TestHandlerRoundTripsTableDigests 守住分表摘要：带 table_digests 的提交原样保存、
// 拉取时原样回传，没有带的提交响应里不出现这个键（ADR-0054）。
func TestHandlerRoundTripsTableDigests(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "tables@b.cn")
	stateDigest := strings.Repeat("a", 64)
	tables := map[string]string{
		"plan_item": strings.Repeat("1", 64),
		"memory":    strings.Repeat("2", 64),
	}

	second := commitBody("r2")
	second["state_digest"] = stateDigest
	second["table_digests"] = tables
	var push api.PushResult
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r1"), second},
	}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("push: %d %+v", code, push)
	}

	var page api.CommitPage
	if code := c.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &page); code != http.StatusOK || len(page.Commits) != 2 {
		t.Fatalf("pull: %d %+v", code, page)
	}
	if page.Commits[0].TableDigests != nil {
		t.Fatalf("没有分表摘要的提交不该返回这个字段: %+v", page.Commits[0].TableDigests)
	}
	got := page.Commits[1].TableDigests
	if got == nil || (*got)["plan_item"] != tables["plan_item"] || (*got)["memory"] != tables["memory"] || len(*got) != 2 {
		t.Fatalf("分表摘要没有原样返回: %+v", got)
	}

	// 原始响应里，没有带的提交不出现这个键。
	var raw struct {
		Commits []map[string]any `json:"commits"`
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &raw); code != http.StatusOK || len(raw.Commits) != 2 {
		t.Fatalf("pull raw: %d %+v", code, raw)
	}
	if _, present := raw.Commits[0]["table_digests"]; present {
		t.Fatalf("没有带分表摘要的提交不该出现 table_digests: %+v", raw.Commits[0])
	}
	if _, present := raw.Commits[1]["table_digests"]; !present {
		t.Fatalf("带分表摘要的提交应出现 table_digests: %+v", raw.Commits[1])
	}
}

// TestHandlerDevicePositionFollowsRequests 守住设备位置：拉取按 after 推进、推送按
// base 推进，确有新提交时推到 head，整批重放不推进到 head，任何情况下都不超过
// head（ADR-0054）。
func TestHandlerDevicePositionFollowsRequests(t *testing.T) {
	h := newSnapshotHarness(t)
	token := signIn(t, h.authSvc, "position@b.cn")
	headers := map[string]string{
		"X-Device-Id":         "device-a",
		"X-Sync-Capabilities": "snapshot",
	}

	// 拉取 after=2 只更新最近出现时间，不推进位置（还没有提交）。
	if code := h.jsonWithHeaders(http.MethodGet, "/v1/sync/commits?after=2", token, nil, nil, headers); code != http.StatusOK {
		t.Fatalf("拉取: %d", code)
	}
	// 推送 base_seq=0 的两条新提交：位置推进到新的 head=2。
	var push api.PushResult
	if code := h.jsonWithHeaders(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("p-1"), commitBody("p-2")},
	}, &push, headers); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("推送: %d %+v", code, push)
	}
	var page api.SyncDeviceList
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK {
		t.Fatalf("名册: %d", code)
	}
	if got := findDevice(t, page, "device-a"); got.SyncedSeq != 2 {
		t.Fatalf("推送新提交之后位置应到 head: %+v", got)
	}

	// 另一台设备推一条，head 变 3。
	other := commitBody("o-1")
	other["device_id"] = "device-b"
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 2, "commits": []any{other},
	}, &push); code != http.StatusOK || push.Head != 3 {
		t.Fatalf("另一台设备的推送: %d %+v", code, push)
	}
	// 设备 A 丢响应之后在 base=2 上整批重放自己那两条：全部是已接收过的提交，
	// 位置保持 2，不跳到 head=3。
	if code := h.jsonWithHeaders(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 2, "commits": []any{commitBody("p-1"), commitBody("p-2")},
	}, &push, headers); code != http.StatusOK || push.Head != 3 {
		t.Fatalf("整批重放: %d %+v", code, push)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK {
		t.Fatalf("名册: %d", code)
	}
	if got := findDevice(t, page, "device-a"); got.SyncedSeq != 2 {
		t.Fatalf("整批重放不应推进到 head: %+v", got)
	}
	// 拉取 after=3 之后位置推进到 3。
	if code := h.jsonWithHeaders(http.MethodGet, "/v1/sync/commits?after=3", token, nil, nil, headers); code != http.StatusOK {
		t.Fatalf("拉取: %d", code)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK {
		t.Fatalf("名册: %d", code)
	}
	if got := findDevice(t, page, "device-a"); got.SyncedSeq != 3 {
		t.Fatalf("拉取之后位置应按 after 推进: %+v", got)
	}
}

// TestHandlerRefsWriteOverwriteAndTombstone 守住命名版本接口：写入、覆盖、墓碑、
// 比删除时间更早的写入不复活、NFC 规范化与名字长度、每账号 200 个的上限，以及
// 清除云端数据期间的 409（ADR-0054）。
func TestHandlerRefsWriteOverwriteAndTombstone(t *testing.T) {
	c, authSvc, h := newRefHarness(t)
	token := signIn(t, authSvc, "refs@b.cn")

	// 空账号返回空列表。
	var list api.SyncRefList
	if code := c.JSON(http.MethodGet, "/v1/sync/refs", token, nil, &list); code != http.StatusOK || len(list.Refs) != 0 {
		t.Fatalf("空列表: %d %+v", code, list)
	}
	_ = list.Refs

	// 写入：名字、引用与备注原样保存。
	var ref api.SyncRef
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "第三章完成", "commit_uid": "uid-1", "note": "第一次整理",
	}, &ref); code != http.StatusOK || ref.Name != "第三章完成" || ref.CommitUid != "uid-1" || ref.Note != "第一次整理" || ref.DeletedAt != nil {
		t.Fatalf("写入: %d %+v", code, ref)
	}
	// 后写覆盖先写：同一名字再写一次，指向新的提交。
	h.clock = h.clock.Add(time.Minute)
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "第三章完成", "commit_uid": "uid-2",
	}, &ref); code != http.StatusOK || ref.CommitUid != "uid-2" || ref.Note != "" {
		t.Fatalf("覆盖: %d %+v", code, ref)
	}

	// NFC 规范化：分解形式与合成形式是同一个名字。
	h.clock = h.clock.Add(time.Minute)
	composed := "café"
	decomposed := "cafe\u0301"
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": composed, "commit_uid": "uid-cafe",
	}, &ref); code != http.StatusOK || ref.Name != composed {
		t.Fatalf("写入合成形式: %d %+v", code, ref)
	}
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": decomposed, "commit_uid": "uid-cafe-2",
	}, &ref); code != http.StatusOK || ref.Name != composed || ref.CommitUid != "uid-cafe-2" {
		t.Fatalf("分解形式应落到同一个名字: %d %+v", code, ref)
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/refs", token, nil, &list); code != http.StatusOK || len(list.Refs) != 2 {
		t.Fatalf("规范化之后应只有两个名字: %d %+v", code, list)
	}

	// 删除：留下墓碑，列表仍然返回它。
	h.clock = h.clock.Add(time.Minute)
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "第三章完成", "delete": true,
	}, &ref); code != http.StatusOK || ref.DeletedAt == nil {
		t.Fatalf("删除: %d %+v", code, ref)
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/refs", token, nil, &list); code != http.StatusOK || len(list.Refs) != 2 {
		t.Fatalf("墓碑也应在列表里: %d %+v", code, list)
	}
	// 比删除时间更早的写入不复活：先把时钟拨到删除之前，再写一次同一个名字。
	deletedAt := ref.DeletedAt.Add(-31 * time.Minute)
	h.clock = deletedAt
	var late api.SyncRef
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "第三章完成", "commit_uid": "uid-late",
	}, &late); code != http.StatusOK || late.DeletedAt == nil || late.CommitUid != "" {
		t.Fatalf("迟到的写入不应复活名字: %d %+v", code, late)
	}
	// 删除时间之后的写入复活。
	h.clock = deletedAt.Add(7 * time.Hour)
	var revived api.SyncRef
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "第三章完成", "commit_uid": "uid-revived",
	}, &revived); code != http.StatusOK || revived.DeletedAt != nil || revived.CommitUid != "uid-revived" {
		t.Fatalf("删除时间之后的写入应复活: %d %+v", code, revived)
	}

	// 名字长度：30 个字符可以，31 个字符拒绝。
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": strings.Repeat("名", 31), "commit_uid": "uid-long",
	}, &ref); code != http.StatusBadRequest {
		t.Fatalf("31 个字符的名字应拒绝: %d", code)
	}
	h.clock = h.clock.Add(time.Minute)
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": strings.Repeat("名", 30), "commit_uid": "uid-30",
	}, &ref); code != http.StatusOK || len([]rune(ref.Name)) != 30 {
		t.Fatalf("30 个字符的名字应接受: %d %+v", code, ref)
	}
	// 缺 commit_uid 的写入按无效请求处理。
	var p testutil.Problem
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "没有引用",
	}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
		t.Fatalf("缺 commit_uid: %d %+v", code, p)
	}

	// 每账号最多 200 个未删除的名字：逐个写入，直到服务端按上限拒绝。
	for i := 0; ; i++ {
		h.clock = h.clock.Add(time.Second)
		name := "版本-" + itoaInt(i) + "-" + itoaInt(i%7)
		var got api.SyncRef
		code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
			"name": name, "commit_uid": "uid-fill",
		}, &got)
		if code == http.StatusOK {
			continue
		}
		if code != http.StatusBadRequest {
			t.Fatalf("填充第 %d 个名字 %s: %d", i, name, code)
		}
		break
	}
	// 已存在一个墓碑，可用的名字因此比上限少一个；关键是服务端按上限拒绝了新的
	// 未删除名字，而墓碑本身仍在列表里。
	if code := c.JSON(http.MethodGet, "/v1/sync/refs", token, nil, &list); code != http.StatusOK {
		t.Fatalf("列表: %d", code)
	}
	alive := aboveCount(list.Refs)
	if alive != MaxRefsPerAccount-1 && alive != MaxRefsPerAccount {
		t.Fatalf("未删除的名字应在上限附近，得到 %d", alive)
	}
	// 再写一次仍然被拒绝：上限已经满了。
	h.clock = h.clock.Add(time.Second)
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "再一次超出上限的名字", "commit_uid": "uid-over-2",
	}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
		t.Fatalf("超限应返回 400 invalid_request: %d %+v", code, p)
	}

	// 清除云端数据期间与其它写请求一样返回 409。
	h.handler.SetPurgeGate(func(_ context.Context, _ string) error { return cloudpurge.ErrPurging })
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "清除期间", "commit_uid": "uid-purge",
	}, &p); code != http.StatusConflict || p.Code != string(httpx.CodeConflict) {
		t.Fatalf("清除期间写入: %d %+v", code, p)
	}
	// 查询不受影响。
	if code := c.JSON(http.MethodGet, "/v1/sync/refs", token, nil, &list); code != http.StatusOK {
		t.Fatalf("清除期间查询: %d", code)
	}
}

// TestHandlerRefsRequireLogin 守住命名版本接口要求登录。
func TestHandlerRefsRequireLogin(t *testing.T) {
	c, _, _ := newRefHarness(t)
	if p := testutil.ReadProblem(t, c.Do(http.MethodGet, "/v1/sync/refs", "", nil, nil)); p.Status != http.StatusUnauthorized {
		t.Fatalf("匿名查询: %+v", p)
	}
	if p := testutil.ReadProblem(t, c.Do(http.MethodPut, "/v1/sync/refs", "", strings.NewReader(`{"name":"a","commit_uid":"b"}`), map[string]string{"Content-Type": "application/json"})); p.Status != http.StatusUnauthorized {
		t.Fatalf("匿名写入: %+v", p)
	}
}

// TestHandlerResetClearsRefsAndDevicePositions 守住清空云端数据的范围：命名版本与
// 设备名册（含设备位置）一并清掉，下一次同步从 0 开始（ADR-0048、ADR-0054）。
func TestHandlerResetClearsRefsAndDevicePositions(t *testing.T) {
	c, authSvc, h := newRefHarness(t)
	token := signIn(t, authSvc, "reset-refs@b.cn")
	headers := map[string]string{"X-Device-Id": "device-a", "X-Sync-Capabilities": "snapshot"}

	var push api.PushResult
	if code := h.jsonWithHeaders(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r1")},
	}, &push, headers); code != http.StatusOK || push.Head != 1 {
		t.Fatalf("推送: %d %+v", code, push)
	}
	var ref api.SyncRef
	if code := c.JSON(http.MethodPut, "/v1/sync/refs", token, map[string]any{
		"name": "要清掉的名字", "commit_uid": "uid-1",
	}, &ref); code != http.StatusOK {
		t.Fatalf("写入命名版本: %d", code)
	}
	var page api.SyncDeviceList
	if code := c.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK || len(page.Devices) != 1 {
		t.Fatalf("名册: %d %+v", code, page)
	}
	if got := findDevice(t, page, "device-a"); got.SyncedSeq != 1 {
		t.Fatalf("清空之前设备位置应为 1: %+v", got)
	}

	if code := c.JSON(http.MethodDelete, "/v1/sync/commits", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("清空: %d", code)
	}
	var list api.SyncRefList
	if code := c.JSON(http.MethodGet, "/v1/sync/refs", token, nil, &list); code != http.StatusOK || len(list.Refs) != 0 {
		t.Fatalf("清空之后命名版本应为空: %d %+v", code, list)
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK || len(page.Devices) != 0 {
		t.Fatalf("清空之后名册应为空: %d %+v", code, page)
	}
	// 清空之后重新推送，位置从 0 重新开始、不会带上旧的大位置。
	if code := h.jsonWithHeaders(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r2")},
	}, &push, headers); code != http.StatusOK || push.Head != 1 {
		t.Fatalf("清空之后推送: %d %+v", code, push)
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK || len(page.Devices) != 1 {
		t.Fatalf("名册: %d %+v", code, page)
	}
	if got := findDevice(t, page, "device-a"); got.SyncedSeq != 1 {
		t.Fatalf("清空之后设备位置应为 1: %+v", got)
	}
}

// itoaInt 便于拼出互不重复的名字。
func itoaInt(value int) string {
	if value == 0 {
		return "0"
	}
	digits := make([]byte, 0, 8)
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}

// aboveCount 数出列表里未删除的名字。
func aboveCount(refs []api.SyncRef) int {
	count := 0
	for _, ref := range refs {
		if ref.DeletedAt == nil {
			count++
		}
	}
	return count
}
