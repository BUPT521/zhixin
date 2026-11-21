package syncsvc

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
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

const (
	// testSchemaVersion 与服务端接受的客户端 schema 版本一致（server.ClientSchemaVersion）。
	testSchemaVersion = 30
	testMaxJSON       = 1 << 20
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) GetV1SyncHead(w http.ResponseWriter, r *http.Request, params api.GetV1SyncHeadParams) {
	a.h.Head(w, r, params)
}

func (a testAPI) GetV1SyncCommits(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	a.h.Pull(w, r, params)
}

func (a testAPI) PostV1SyncCommits(w http.ResponseWriter, r *http.Request, params api.PostV1SyncCommitsParams) {
	a.h.Push(w, r, params)
}

func (a testAPI) DeleteV1SyncCommits(w http.ResponseWriter, r *http.Request) { a.h.Reset(w, r) }

func (a testAPI) GetV1SyncDevices(w http.ResponseWriter, r *http.Request) { a.h.Devices(w, r) }

func (a testAPI) PutV1SyncDevices(w http.ResponseWriter, r *http.Request) { a.h.RenameDevice(w, r) }

// newTestServer 装配本包处理器与鉴权中间件，返回客户端与用于签发测试令牌的
// 账号服务；限流由 server 包统一测。
func newTestServer(t *testing.T) (*testutil.Client, *auth.Service) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(NewMemoryStore(), testSchemaVersion), log, 16*testMaxJSON)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: handler},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc
}

// signIn 注册一个测试账号并返回访问令牌。
func signIn(t *testing.T, svc *auth.Service, email string) string {
	t.Helper()
	tokens, err := svc.Register(context.Background(), email, "password1", "")
	if err != nil {
		t.Fatalf("register %s: %v", email, err)
	}
	return tokens.AccessToken
}

// TestHandlerWriteBlockedDuringPurge 守住清除期间的写拦截：gate 返回
// cloudpurge.ErrPurging 时 Push 与 Reset 回 409 conflict，拉取仍可读，且没有
// 写入任何提交。
func TestHandlerWriteBlockedDuringPurge(t *testing.T) {
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(NewMemoryStore(), testSchemaVersion), log, 16*testMaxJSON)
	handler.SetPurgeGate(func(context.Context, string) error { return cloudpurge.ErrPurging })
	c := testutil.NewClient(t, testutil.NewServer(
		testAPI{h: handler},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	))
	token := signIn(t, authSvc, "a@b.cn")

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token,
		map[string]any{"base_seq": 0, "commits": []any{commitBody("r1")}}, &p); code != http.StatusConflict || p.Code != string(httpx.CodeConflict) {
		t.Fatalf("push during purge: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodDelete, "/v1/sync/commits", token, nil, nil); code != http.StatusConflict {
		t.Fatalf("reset during purge: %d", code)
	}
	var page api.CommitPage
	if code := c.JSON(http.MethodGet, "/v1/sync/commits", token, nil, &page); code != http.StatusOK || len(page.Commits) != 0 {
		t.Fatalf("pull during purge: %d %+v", code, page)
	}
}

func commitBody(reqID string) map[string]any {
	return map[string]any{
		"request_id":     reqID,
		"device_id":      "device-a",
		"schema_version": testSchemaVersion,
		"actor":          "user",
		"action":         "create_plan_item",
		"created_at":     "2026-11-14 09:00:00",
		"changes": []map[string]any{{
			"table": "plan_item", "row_key": "01JD", "op": "insert",
			"after": map[string]any{"title": "复习第三章"},
		}},
	}
}

func TestHandlerSyncIsLinearAndIdempotent(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "a@b.cn")

	var push api.PushResult
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{"base_seq": 0, "commits": []any{commitBody("r1"), commitBody("r2")}}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("first push: %d %+v", code, push)
	}
	// Retrying the same push after a lost response is harmless.
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{"base_seq": 0, "commits": []any{commitBody("r1"), commitBody("r2")}}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("replayed push: %d %+v", code, push)
	}
	// Another device pushing on a stale base must pull first.
	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{"base_seq": 1, "commits": []any{commitBody("r3")}}, &p); code != http.StatusConflict || p.Code != string(httpx.CodeConflict) || p.Extra["head"] != float64(2) {
		t.Fatalf("stale push: %d %+v", code, p)
	}

	var pull api.CommitPage
	if code := c.JSON(http.MethodGet, "/v1/sync/commits?after=0&limit=1", token, nil, &pull); code != http.StatusOK || len(pull.Commits) != 1 || !pull.HasMore || pull.Commits[0].RequestId != "r1" {
		t.Fatalf("pull page 1: %d %+v", code, pull)
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/commits?after=1", token, nil, &pull); code != http.StatusOK || len(pull.Commits) != 1 || pull.HasMore || pull.Commits[0].Seq == nil || *pull.Commits[0].Seq != 2 {
		t.Fatalf("pull page 2: %d %+v", code, pull)
	}

	bad := commitBody("r4")
	bad["schema_version"] = testSchemaVersion - 1
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{"base_seq": 2, "commits": []any{bad}}, &p); code != http.StatusBadRequest {
		t.Fatalf("old schema accepted: %d", code)
	}

	// Logs are per account.
	other := signIn(t, authSvc, "c@d.cn")
	if code := c.JSON(http.MethodGet, "/v1/sync/commits", other, nil, &pull); code != http.StatusOK || len(pull.Commits) != 0 || pull.Head != 0 {
		t.Fatalf("leaked across accounts: %d %+v", code, pull)
	}
}

// TestHandlerResetClearsLogAndHead 守住“清除云端数据（保留账号）”：
// 清空当前账号的提交序列并把 head 重置为 0，另一个账号与账号本身不受影响；
// 重置之后从 0 重新推送可以正常分配序号；未带令牌返回 401。
func TestHandlerResetClearsLogAndHead(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "a@b.cn")
	other := signIn(t, authSvc, "c@d.cn")

	var push api.PushResult
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{"base_seq": 0, "commits": []any{commitBody("r1"), commitBody("r2")}}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("push: %d %+v", code, push)
	}
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", other, map[string]any{"base_seq": 0, "commits": []any{commitBody("other-1")}}, &push); code != http.StatusOK || push.Head != 1 {
		t.Fatalf("other push: %d %+v", code, push)
	}

	if code := c.JSON(http.MethodDelete, "/v1/sync/commits", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("clear commits: %d", code)
	}

	var head api.SyncHead
	if code := c.JSON(http.MethodGet, "/v1/sync/head", token, nil, &head); code != http.StatusOK || head.Head != 0 {
		t.Fatalf("head after clear: %d %+v", code, head)
	}
	var page api.CommitPage
	if code := c.JSON(http.MethodGet, "/v1/sync/commits", token, nil, &page); code != http.StatusOK || len(page.Commits) != 0 || page.Head != 0 {
		t.Fatalf("page after clear: %d %+v", code, page)
	}
	// 序号从 0 重新开始，客户端按 base_seq=0 推送即可。
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{"base_seq": 0, "commits": []any{commitBody("r3")}}, &push); code != http.StatusOK || push.Head != 1 {
		t.Fatalf("push after clear: %d %+v", code, push)
	}
	// 重复调用是幂等的。
	if code := c.JSON(http.MethodDelete, "/v1/sync/commits", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("second clear: %d", code)
	}

	// 另一个账号的序列不受影响。
	if code := c.JSON(http.MethodGet, "/v1/sync/head", other, nil, &head); code != http.StatusOK || head.Head != 1 {
		t.Fatalf("other head after clear: %d %+v", code, head)
	}

	// 鉴权由中间件负责：没有令牌时处理器根本不会被调用。
	p := testutil.ReadProblem(t, c.Do(http.MethodDelete, "/v1/sync/commits", "", nil, nil))
	if p.Status != http.StatusUnauthorized || p.Code != string(httpx.CodeUnauthorized) {
		t.Fatalf("anonymous clear: %+v", p)
	}
}

// TestHandlerSyncPreservesLargeIntegers 守护契约对 before/after 的声明：行内容按
// json.RawMessage 原样转发。若退回 interface{}，这里的大整数会经 float64 往返
// 变成 9007199254740992。
func TestHandlerSyncPreservesLargeIntegers(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "big@b.cn")

	const big = "9007199254740993"
	body := fmt.Sprintf(`{"base_seq":0,"commits":[{
		"request_id":"big-1","device_id":"device-a","schema_version":%d,
		"actor":"user","action":"create","created_at":"2026-11-15 10:00:00",
		"changes":[{"table":"memory","row_key":"1","op":"insert","after":{"id":%s}}]}]}`,
		testSchemaVersion, big)
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, json.RawMessage(body), nil); code != http.StatusOK {
		t.Fatalf("push: %d", code)
	}

	var pulled struct {
		Commits []struct {
			Changes json.RawMessage `json:"changes"`
		} `json:"commits"`
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &pulled); code != http.StatusOK || len(pulled.Commits) != 1 {
		t.Fatalf("pull: %d %+v", code, pulled)
	}
	if !strings.Contains(string(pulled.Commits[0].Changes), big) {
		t.Fatalf("large integer was rewritten: %s", pulled.Commits[0].Changes)
	}
}

// ---- 快照登记与保留下界的处理器用例（ADR-0043） ----
//
// 以下内容追加在文件末尾：另一个同事同时在改文件头部的 schema 常量，这里只补
// 新的桩与用例，不重写已有的 testAPI 与常量。

// snapshotAPI 在 testAPI 之上补齐快照的两条路由；testutil.Base 里已经有回 404
// 的桩，契约新增接口时那边会先编译失败。
type snapshotAPI struct{ testAPI }

func (a snapshotAPI) GetV1SyncSnapshot(w http.ResponseWriter, r *http.Request) {
	a.h.Snapshot(w, r)
}

func (a snapshotAPI) PutV1SyncSnapshot(w http.ResponseWriter, r *http.Request, params api.PutV1SyncSnapshotParams) {
	a.h.RegisterSnapshot(w, r, params)
}

// snapshotHarness 是一套带可控时钟与附件查询的同步服务：保留期要在用例里直接
// 拨动，附件归属用一个只认测试哈希的查询模拟。
type snapshotHarness struct {
	t       *testing.T
	client  *testutil.Client
	authSvc *auth.Service
	store   *MemoryStore
	clock   time.Time
}

func newSnapshotHarness(t *testing.T) *snapshotHarness {
	t.Helper()
	h := &snapshotHarness{t: t, store: NewMemoryStore(), clock: time.Now()}
	h.store.now = func() time.Time { return h.clock }
	h.authSvc = auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := NewService(h.store, testSchemaVersion).
		SetAttachments(fakeAttachments{snapshotSHA: 4096}).
		SetCompact(true).
		SetCompactKeep(time.Hour)
	handler := NewHandler(svc, log, 16*testMaxJSON)
	h.client = testutil.NewClient(t, testutil.NewServer(
		snapshotAPI{testAPI{h: handler}},
		httpx.RequestID,
		auth.Middleware(h.authSvc, log),
	))
	return h
}

// snapshotBody 是一次快照登记的请求体。
func snapshotBody(seq int64, sha string) map[string]any {
	return map[string]any{"seq": seq, "sha256": sha, "digest": snapshotDigest}
}

// syncJSON 发一次带设备标识与能力声明的请求：压缩门槛要看名册，用例里的设备
// 必须在请求头里声明 snapshot 才会允许删除提交（ADR-0047、ADR-0048）。
func (h *snapshotHarness) syncJSON(method, path, token string, in, out any) int {
	h.t.Helper()
	return h.jsonWithHeaders(method, path, token, in, out, map[string]string{
		"X-Device-Id":         "device-a",
		"X-Sync-Capabilities": "snapshot",
	})
}

// jsonWithHeaders 与 syncJSON 相同，只是请求头由调用方给出。
func (h *snapshotHarness) jsonWithHeaders(method, path, token string, in, out any, headers map[string]string) int {
	h.t.Helper()
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			h.t.Fatalf("%s %s: marshal: %v", method, path, err)
		}
		body = bytes.NewReader(b)
	}
	all := map[string]string{"Content-Type": "application/json"}
	for key, value := range headers {
		all[key] = value
	}
	resp := h.client.Do(method, path, token, body, all)
	defer resp.Body.Close()
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil && err != io.EOF {
			h.t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return resp.StatusCode
}

// TestHandlerSnapshotRegistration 守住新接口的鉴权、参数校验与登记语义：不能
// 登记未来的位置，附件必须属于这个账号，不能回退覆盖更新的快照，同一位置按幂等
// 重试接受；head 与快照查询返回同一个指针。
func TestHandlerSnapshotRegistration(t *testing.T) {
	h := newSnapshotHarness(t)
	token := signIn(t, h.authSvc, "snap@b.cn")

	var push api.PushResult
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r1"), commitBody("r2")},
	}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("push: %d %+v", code, push)
	}

	// 鉴权由中间件负责：没有令牌时处理器根本不会被调用。
	anonPut := testutil.ReadProblem(t, h.client.Do(http.MethodPut, "/v1/sync/snapshot", "", strings.NewReader(`{"seq":1,"sha256":"`+snapshotSHA+`","digest":"`+snapshotDigest+`"}`), map[string]string{"Content-Type": "application/json"}))
	if anonPut.Status != http.StatusUnauthorized || anonPut.Code != string(httpx.CodeUnauthorized) {
		t.Fatalf("匿名登记: %+v", anonPut)
	}
	anonGet := testutil.ReadProblem(t, h.client.Do(http.MethodGet, "/v1/sync/snapshot", "", nil, nil))
	if anonGet.Status != http.StatusUnauthorized {
		t.Fatalf("匿名查询: %+v", anonGet)
	}

	// 参数校验：未来的位置、形状不对的哈希、不属于这个账号的附件、不是 JSON。
	var p testutil.Problem
	bad := []struct {
		name string
		body any
	}{
		{"未来的位置", snapshotBody(3, snapshotSHA)},
		{"序号为零", snapshotBody(0, snapshotSHA)},
		{"哈希形状不对", snapshotBody(1, "not-a-hash")},
		{"摘要形状不对", map[string]any{"seq": 1, "sha256": snapshotSHA, "digest": strings.Repeat("c", 63)}},
		{"附件不属于这个账号", snapshotBody(1, strings.Repeat("d", 64))},
	}
	for _, tc := range bad {
		if code := h.client.JSON(http.MethodPut, "/v1/sync/snapshot", token, tc.body, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
			t.Fatalf("%s: %d %+v", tc.name, code, p)
		}
	}
	if code := h.client.JSON(http.MethodPut, "/v1/sync/snapshot", token, map[string]any{"seq": 1}, &p); code != http.StatusBadRequest {
		t.Fatalf("缺字段: %d %+v", code, p)
	}

	// 合法登记：head、保留下界与快照指针一起返回。
	var head api.SyncHead
	if code := h.client.JSON(http.MethodPut, "/v1/sync/snapshot", token, snapshotBody(2, snapshotSHA), &head); code != http.StatusOK || head.Head != 2 || head.EarliestSeq != 1 || head.Snapshot == nil || head.Snapshot.Seq != 2 || head.Snapshot.Sha256 != snapshotSHA {
		t.Fatalf("登记快照: %d %+v", code, head)
	}
	var snap api.SyncHead
	if code := h.client.JSON(http.MethodGet, "/v1/sync/snapshot", token, nil, &snap); code != http.StatusOK || snap.Snapshot == nil || *snap.Snapshot != *head.Snapshot {
		t.Fatalf("查询快照: %d %+v", code, snap)
	}

	// 回退覆盖更新的快照被拒绝，extra 给出当前位置。
	if code := h.client.JSON(http.MethodPut, "/v1/sync/snapshot", token, snapshotBody(1, snapshotSHA), &p); code != http.StatusConflict || p.Code != string(httpx.CodeConflict) || p.Extra["snapshot_seq"] != float64(2) {
		t.Fatalf("回退登记: %d %+v", code, p)
	}
	// 同一位置的登记按幂等重试接受。
	if code := h.client.JSON(http.MethodPut, "/v1/sync/snapshot", token, snapshotBody(2, snapshotSHA), &head); code != http.StatusOK || head.Snapshot == nil || head.Snapshot.Seq != 2 {
		t.Fatalf("同位置重试: %d %+v", code, head)
	}

	// 序列本身不受登记影响：提交还在，head 与拉取都不变。
	var page api.CommitPage
	if code := h.client.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &page); code != http.StatusOK || len(page.Commits) != 2 || page.EarliestSeq != 1 || page.Snapshot == nil || page.Snapshot.Seq != 2 {
		t.Fatalf("登记之后拉取: %d %+v", code, page)
	}

	// 另一个账号看不到这个账号的快照。响应里没有 snapshot 字段时解码不会覆盖旧
	// 值，所以这里用一个新变量。
	other := signIn(t, h.authSvc, "other@b.cn")
	var otherHead api.SyncHead
	if code := h.client.JSON(http.MethodGet, "/v1/sync/snapshot", other, nil, &otherHead); code != http.StatusOK || otherHead.Snapshot != nil || otherHead.Head != 0 || otherHead.EarliestSeq != 1 {
		t.Fatalf("跨账号泄漏: %d %+v", code, otherHead)
	}
}

// TestHandlerPullAfterCompaction 守住压缩之后的拉取边界：要的下一条已删除时返回
// 410 history_compacted 并带上保留下界与快照位置，恰好接得上的位置照常增量返回。
func TestHandlerPullAfterCompaction(t *testing.T) {
	h := newSnapshotHarness(t)
	token := signIn(t, h.authSvc, "compact@b.cn")

	for i := range 4 {
		var push api.PushResult
		if code := h.syncJSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
			"base_seq": i, "commits": []any{commitBody(fmt.Sprintf("r%d", i))},
		}, &push); code != http.StatusOK || push.Head != int64(i+1) {
			t.Fatalf("push %d: %d %+v", i, code, push)
		}
	}
	var page api.CommitPage
	if code := h.client.JSON(http.MethodGet, "/v1/sync/commits?after=0", token, nil, &page); code != http.StatusOK || len(page.Commits) != 4 || page.EarliestSeq != 1 || page.Snapshot != nil {
		t.Fatalf("压缩之前拉取: %d %+v", code, page)
	}

	// 拨过保留期再登记快照，四条提交都早于保留窗口，登记时删除。
	h.clock = h.clock.Add(2 * time.Hour)
	var head api.SyncHead
	if code := h.syncJSON(http.MethodPut, "/v1/sync/snapshot", token, snapshotBody(4, snapshotSHA), &head); code != http.StatusOK || head.Head != 4 || head.EarliestSeq != 5 || head.Snapshot == nil || head.Snapshot.Seq != 4 {
		t.Fatalf("压缩之后登记: %d %+v", code, head)
	}

	// 越界的位置返回 410，extra 带齐重新克隆需要的信息。
	compacted := testutil.ReadProblem(t, h.client.Do(http.MethodGet, "/v1/sync/commits?after=1", token, nil, nil))
	if compacted.Status != http.StatusGone || compacted.Code != string(httpx.CodeHistoryCompacted) {
		t.Fatalf("越界拉取: %+v", compacted)
	}
	if compacted.Extra["after"] != float64(1) || compacted.Extra["earliest_seq"] != float64(5) ||
		compacted.Extra["head"] != float64(4) || compacted.Extra["snapshot_seq"] != float64(4) ||
		compacted.Extra["snapshot_sha256"] != snapshotSHA || compacted.Extra["snapshot_digest"] != snapshotDigest {
		t.Fatalf("越界拉取的 extra: %+v", compacted.Extra)
	}
	// 首次同步的位置同样越界，客户端应当先下载快照。
	if p := testutil.ReadProblem(t, h.client.Do(http.MethodGet, "/v1/sync/commits?after=0", token, nil, nil)); p.Status != http.StatusGone || p.Code != string(httpx.CodeHistoryCompacted) {
		t.Fatalf("首次同步的位置: %+v", p)
	}

	// 恰好等于保留下界减一时仍按增量返回。
	if code := h.client.JSON(http.MethodGet, "/v1/sync/commits?after=4", token, nil, &page); code != http.StatusOK || len(page.Commits) != 0 || page.Head != 4 || page.EarliestSeq != 5 {
		t.Fatalf("边界位置拉取: %d %+v", code, page)
	}

	// 压缩之后的提交照常追加与拉取。
	var push api.PushResult
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 4, "commits": []any{commitBody("r5")},
	}, &push); code != http.StatusOK || push.Head != 5 {
		t.Fatalf("压缩之后推送: %d %+v", code, push)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/commits?after=4", token, nil, &page); code != http.StatusOK || len(page.Commits) != 1 || page.Commits[0].RequestId != "r5" || page.EarliestSeq != 5 {
		t.Fatalf("压缩之后的增量: %d %+v", code, page)
	}
}

// TestHandlerSnapshotBlockedDuringPurge 守住清除云端数据期间的写拦截：登记快照
// 与推送、重置一样返回 409，查询不受影响。
func TestHandlerSnapshotBlockedDuringPurge(t *testing.T) {
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := NewService(NewMemoryStore(), testSchemaVersion).SetAttachments(fakeAttachments{snapshotSHA: 4096})
	handler := NewHandler(svc, log, 16*testMaxJSON)
	handler.SetPurgeGate(func(context.Context, string) error { return cloudpurge.ErrPurging })
	c := testutil.NewClient(t, testutil.NewServer(
		snapshotAPI{testAPI{h: handler}},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	))
	token := signIn(t, authSvc, "purge-snap@b.cn")

	var p testutil.Problem
	if code := c.JSON(http.MethodPut, "/v1/sync/snapshot", token, snapshotBody(1, snapshotSHA), &p); code != http.StatusConflict || p.Code != string(httpx.CodeConflict) {
		t.Fatalf("清除期间登记: %d %+v", code, p)
	}
	var head api.SyncHead
	if code := c.JSON(http.MethodGet, "/v1/sync/snapshot", token, nil, &head); code != http.StatusOK || head.Head != 0 || head.EarliestSeq != 1 {
		t.Fatalf("清除期间查询: %d %+v", code, head)
	}
}

// TestHandlerRoundTripsOptionalStateDigest 守住推送与拉取之间的可选摘要：带
// state_digest 的提交原样保存、拉取时原样返回，没有带的提交响应里不出现这个键
// （改进方案 3.5）。服务端只转发，不解析摘要内容。
func TestHandlerRoundTripsOptionalStateDigest(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "digest@b.cn")
	digest := strings.Repeat("b", 64)

	second := commitBody("r2")
	second["state_digest"] = digest
	var push api.PushResult
	if code := c.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r1"), second},
	}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("push: %d %+v", code, push)
	}

	var page api.CommitPage
	if code := c.JSON(http.MethodGet, "/v1/sync/commits", token, nil, &page); code != http.StatusOK || len(page.Commits) != 2 {
		t.Fatalf("pull: %d %+v", code, page)
	}
	if page.Commits[0].StateDigest != nil {
		t.Fatalf("没有摘要的提交不该返回这个字段: %v", *page.Commits[0].StateDigest)
	}
	if got := page.Commits[1].StateDigest; got == nil || *got != digest {
		t.Fatalf("摘要没有原样返回: %v", got)
	}

	// 响应是契约生成的类型：没有摘要的提交里不出现 state_digest 键。
	var raw map[string]any
	if code := c.JSON(http.MethodGet, "/v1/sync/commits?after=1", token, nil, &raw); code != http.StatusOK {
		t.Fatalf("pull raw: %d", code)
	}
	commits, ok := raw["commits"].([]any)
	if !ok || len(commits) != 1 {
		t.Fatalf("原始响应: %+v", raw)
	}
	last, ok := commits[0].(map[string]any)
	if !ok || last["state_digest"] != digest {
		t.Fatalf("原始响应的摘要: %+v", commits[0])
	}
	if code := c.JSON(http.MethodGet, "/v1/sync/commits", token, nil, &raw); code != http.StatusOK {
		t.Fatalf("pull raw all: %d", code)
	}
	first, ok := raw["commits"].([]any)[0].(map[string]any)
	if !ok {
		t.Fatalf("原始响应的第一条: %+v", raw["commits"])
	}
	if _, present := first["state_digest"]; present {
		t.Fatalf("没有带摘要的提交不该出现 state_digest: %+v", first)
	}
}

// findDevice 按设备标识在名册响应里找一台设备。
func findDevice(t *testing.T, list api.SyncDeviceList, deviceID string) api.SyncDevice {
	t.Helper()
	for _, device := range list.Devices {
		if device.DeviceId == deviceID {
			return device
		}
	}
	t.Fatalf("名册里没有设备 %s: %+v", deviceID, list.Devices)
	return api.SyncDevice{}
}

// TestHandlerDeviceRoster 守住设备名册的请求路径：带 X-Device-Id 的同步请求更
// 新最近出现时间与能力声明（整组替换，别名不动）；没有请求头的推送按提交里的
// 设备标识补行；GET 与 PUT /v1/sync/devices 返回名册、改别名、未知设备 404，
// 别名按去掉首尾空白之后的字符数校验（ADR-0048）。
func TestHandlerDeviceRoster(t *testing.T) {
	h := newSnapshotHarness(t)
	token := signIn(t, h.authSvc, "devices@b.cn")

	var push api.PushResult
	if code := h.syncJSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 0, "commits": []any{commitBody("r1")},
	}, &push); code != http.StatusOK || push.Head != 1 {
		t.Fatalf("带设备头的推送: %d %+v", code, push)
	}

	var page api.SyncDeviceList
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK || len(page.Devices) != 1 {
		t.Fatalf("名册: %d %+v", code, page)
	}
	first := findDevice(t, page, "device-a")
	if first.Alias != "" || len(first.Capabilities) != 1 || first.Capabilities[0] != "snapshot" || !first.LastSeen.Equal(h.clock) {
		t.Fatalf("第一次记录的设备: %+v", first)
	}

	// 拨快时钟再同步一次，能力整组替换（大小写与空白按逗号拆分规范化）。
	h.clock = h.clock.Add(time.Minute)
	if code := h.jsonWithHeaders(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 1, "commits": []any{commitBody("r2")},
	}, &push, map[string]string{
		"X-Device-Id":         "device-a",
		"X-Sync-Capabilities": "Snapshot, OTHER, snapshot",
	}); code != http.StatusOK {
		t.Fatalf("第二次推送: %d", code)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK {
		t.Fatalf("名册: %d", code)
	}
	second := findDevice(t, page, "device-a")
	if len(second.Capabilities) != 2 || second.Capabilities[0] != "snapshot" || second.Capabilities[1] != "other" {
		t.Fatalf("能力声明应整组替换并规范化: %+v", second.Capabilities)
	}
	if !second.LastSeen.Equal(h.clock) || !second.LastSeen.After(first.LastSeen) {
		t.Fatalf("最近出现时间应更新: first=%v second=%v", first.LastSeen, second.LastSeen)
	}

	// 改名：首尾空白去掉，别名落库并原样返回。
	var renamed api.SyncDevice
	if code := h.client.JSON(http.MethodPut, "/v1/sync/devices", token, map[string]any{
		"device_id": "device-a", "alias": "  我的手机  ",
	}, &renamed); code != http.StatusOK || renamed.Alias != "我的手机" || renamed.DeviceId != "device-a" {
		t.Fatalf("改名: %d %+v", code, renamed)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK {
		t.Fatalf("改名之后的名册: %d", code)
	}
	if got := findDevice(t, page, "device-a"); got.Alias != "我的手机" {
		t.Fatalf("别名没有保存: %+v", got)
	}
	// 空串表示清除。
	if code := h.client.JSON(http.MethodPut, "/v1/sync/devices", token, map[string]any{
		"device_id": "device-a", "alias": "   ",
	}, &renamed); code != http.StatusOK || renamed.Alias != "" {
		t.Fatalf("清除别名: %d %+v", code, renamed)
	}

	// 未知设备返回 404 not_found。
	var p testutil.Problem
	if code := h.client.JSON(http.MethodPut, "/v1/sync/devices", token, map[string]any{
		"device_id": "device-unknown", "alias": "别的手机",
	}, &p); code != http.StatusNotFound || p.Code != string(httpx.CodeNotFound) {
		t.Fatalf("未知设备: %d %+v", code, p)
	}
	// 别名超过 64 个字符、设备标识为空都按无效请求返回 400。
	if code := h.client.JSON(http.MethodPut, "/v1/sync/devices", token, map[string]any{
		"device_id": "device-a", "alias": strings.Repeat("名", 65),
	}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
		t.Fatalf("超长别名: %d %+v", code, p)
	}
	if code := h.client.JSON(http.MethodPut, "/v1/sync/devices", token, map[string]any{
		"device_id": "", "alias": "手机",
	}, &p); code != http.StatusBadRequest {
		t.Fatalf("空设备标识: %d %+v", code, p)
	}
	// 恰好 64 个字符的别名可以保存。
	if code := h.client.JSON(http.MethodPut, "/v1/sync/devices", token, map[string]any{
		"device_id": "device-a", "alias": strings.Repeat("名", 64),
	}, &renamed); code != http.StatusOK || len([]rune(renamed.Alias)) != 64 {
		t.Fatalf("64 字符别名: %d %+v", code, renamed)
	}

	// 没有设备标识的推送按提交里的设备标识补一行，能力与别名留空。
	other := commitBody("r3")
	other["device_id"] = "device-b"
	if code := h.client.JSON(http.MethodPost, "/v1/sync/commits", token, map[string]any{
		"base_seq": 2, "commits": []any{other},
	}, &push); code != http.StatusOK || push.Head != 3 {
		t.Fatalf("没有设备头的推送: %d %+v", code, push)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK || len(page.Devices) != 2 {
		t.Fatalf("补行之后的名册: %d %+v", code, page)
	}
	added := findDevice(t, page, "device-b")
	if added.Alias != "" || len(added.Capabilities) != 0 {
		t.Fatalf("补行设备的别名与能力应为空: %+v", added)
	}

	// 清空云端数据把名册一起清掉。
	if code := h.client.JSON(http.MethodDelete, "/v1/sync/commits", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("清空: %d", code)
	}
	if code := h.client.JSON(http.MethodGet, "/v1/sync/devices", token, nil, &page); code != http.StatusOK || len(page.Devices) != 0 {
		t.Fatalf("清空之后的名册: %d %+v", code, page)
	}
}
