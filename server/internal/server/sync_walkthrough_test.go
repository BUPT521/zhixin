package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"testing"
)

// walkCommit 造一条能通过契约校验的提交；两名设备用不同的 device_id 与
// request_id，模拟客户端各自的提交。
func walkCommit(requestID, deviceID, actor, action string, change map[string]any) map[string]any {
	return map[string]any{
		"request_id":     requestID,
		"device_id":      deviceID,
		"schema_version": ClientSchemaVersion,
		"actor":          actor,
		"action":         action,
		"created_at":     "2026-11-18 09:00:00",
		"changes":        []any{change},
	}
}

func itoa(value int64) string { return strconv.FormatInt(value, 10) }

func testutilReadBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("读响应体：%v", err)
	}
	return b
}

// TestTwoDeviceSyncWalkthrough 按 server/README 的同步协议，用同一账号的两个
// 设备身份把两台设备的使用顺序走一遍：首次基线、两台设备交替推送、同一字段
// 并发修改后的 409 与拉取重推、重复 request_id 重试、附件按哈希补齐，以及清空
// 云端数据之后重新上传基线。服务端不合并字段，后到达服务端的提交覆盖先到达的，
// 被覆盖的值留在提交历史里；用例把这个结论钉住，结果同时记在 README。
func TestTwoDeviceSyncWalkthrough(t *testing.T) {
	h := newHarness(t, nil)
	const email = "walkthrough@b.cn"
	const password = "password1"
	deviceA := h.signUp(email)
	var loginB struct {
		AccessToken string `json:"access_token"`
	}
	if code := h.json("POST", "/v1/auth/login", "", map[string]string{
		"identifier": email, "password": password, "device_name": "device-b",
	}, &loginB); code != http.StatusOK {
		t.Fatalf("设备 B 登录失败：%d", code)
	}
	deviceB := loginB.AccessToken

	// push 推一批提交并返回状态码与服务端 head；失败时 head 是问题体里的 extra。
	push := func(token string, base int64, commits ...map[string]any) (int, int64) {
		t.Helper()
		var ok struct {
			Head int64 `json:"head"`
		}
		var failure problem
		body := map[string]any{"base_seq": base, "commits": commits}
		encoded, _ := json.Marshal(body)
		resp := h.do("POST", "/v1/sync/commits", token, bytes.NewReader(encoded), map[string]string{"Content-Type": "application/json"})
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			if err := json.NewDecoder(resp.Body).Decode(&ok); err != nil {
				t.Fatalf("decode push: %v", err)
			}
			return resp.StatusCode, ok.Head
		}
		_ = json.NewDecoder(resp.Body).Decode(&failure)
		head, _ := failure.Extra["head"].(float64)
		return resp.StatusCode, int64(head)
	}

	// pull 拉 after 之后的提交，返回提交本身与 head。
	type pulled struct {
		Commits []struct {
			Seq       int64  `json:"seq"`
			RequestID string `json:"request_id"`
			DeviceID  string `json:"device_id"`
			Action    string `json:"action"`
		} `json:"commits"`
		Head int64 `json:"head"`
	}
	pull := func(token string, after int64) pulled {
		t.Helper()
		var out pulled
		if code := h.json("GET", "/v1/sync/commits?after="+itoa(after), token, nil, &out); code != http.StatusOK {
			t.Fatalf("拉取 after=%d 失败：%d", after, code)
		}
		return out
	}

	// ---- 1. 设备 A 首次同步：上传当前数据的基线 ----
	baseline := walkCommit("walk-a-baseline", "device-a", "system", "首次同步基线", map[string]any{
		"table": "plan_item", "row_key": "row-x", "op": "insert",
		"after": map[string]any{"title": "第三章", "done": false},
	})
	if code, head := push(deviceA, 0, baseline); code != http.StatusOK || head != 1 {
		t.Fatalf("设备 A 上传基线：%d head=%d", code, head)
	}
	t.Logf("步骤 1：设备 A 以 base_seq=0 上传基线，head=1")

	// ---- 2. 设备 B 首次同步：先拉别人的提交，再推自己的编辑 ----
	page := pull(deviceB, 0)
	if len(page.Commits) != 1 || page.Head != 1 {
		t.Fatalf("设备 B 首次拉取：%+v", page)
	}
	editB := walkCommit("walk-b-edit", "device-b", "user", "完成一次编辑", map[string]any{
		"table": "plan_item", "row_key": "row-x", "op": "update",
		"before": map[string]any{"done": false}, "after": map[string]any{"done": true},
	})
	if code, head := push(deviceB, 1, editB); code != http.StatusOK || head != 2 {
		t.Fatalf("设备 B 推送编辑：%d head=%d", code, head)
	}
	t.Logf("步骤 2：设备 B 拉取 after=0 得到基线，应用后在 base_seq=1 上推自己的编辑，head=2")

	// ---- 3. 设备 A 拉取 B 的编辑，再推自己的编辑 ----
	if page := pull(deviceA, 1); len(page.Commits) != 1 || page.Commits[0].DeviceID != "device-b" {
		t.Fatalf("设备 A 拉取：%+v", page)
	}
	editA := walkCommit("walk-a-edit", "device-a", "user", "新增一条预约", map[string]any{
		"table": "plan_item", "row_key": "row-y", "op": "insert",
		"after": map[string]any{"title": "复习第一章"},
	})
	if code, head := push(deviceA, 2, editA); code != http.StatusOK || head != 3 {
		t.Fatalf("设备 A 推送编辑：%d head=%d", code, head)
	}
	t.Logf("步骤 3：设备 A 拉取 after=1 应用 B 的提交，再以 base_seq=2 推送，head=3")

	// ---- 4. 两台设备并发修改同一行：后到达的覆盖先到达的 ----
	concurrentA := walkCommit("walk-a-concurrent", "device-a", "user", "改标题", map[string]any{
		"table": "plan_item", "row_key": "row-x", "op": "update",
		"before": map[string]any{"title": "第三章"}, "after": map[string]any{"title": "第三章（A 改）"},
	})
	if code, head := push(deviceA, 3, concurrentA); code != http.StatusOK || head != 4 {
		t.Fatalf("设备 A 并发修改：%d head=%d", code, head)
	}
	concurrentB := walkCommit("walk-b-concurrent", "device-b", "user", "改标题", map[string]any{
		"table": "plan_item", "row_key": "row-x", "op": "update",
		"before": map[string]any{"title": "第三章"}, "after": map[string]any{"title": "第三章（B 改）"},
	})
	if code, head := push(deviceB, 3, concurrentB); code != http.StatusConflict || head != 4 {
		t.Fatalf("设备 B 用旧位置推送应得到 409 与最新 head：%d head=%d", code, head)
	}
	t.Logf("步骤 4：设备 B 以旧 base_seq=3 推送，得到 409，extra.head=4")

	// 设备 B 先拉取 A 的提交，在本地应用为新的提交之后再推：base_seq=4。
	if page := pull(deviceB, 3); len(page.Commits) != 1 {
		t.Fatalf("设备 B 拉取并发冲突：%+v", page)
	}
	reconciled := walkCommit("walk-b-reconciled", "device-b", "user", "改标题", map[string]any{
		"table": "plan_item", "row_key": "row-x", "op": "update",
		"before": map[string]any{"title": "第三章（A 改）"}, "after": map[string]any{"title": "第三章（B 改）"},
	})
	if code, head := push(deviceB, 4, reconciled); code != http.StatusOK || head != 5 {
		t.Fatalf("设备 B 拉取后重推：%d head=%d", code, head)
	}
	t.Logf("步骤 5：设备 B 拉取 after=3 应用 A 的提交，以 base_seq=4 重推，head=5")

	// ---- 5. 提交历史保留先后两条：后到达的 B 是当前值，A 的值仍在历史里 ----
	history := pull(deviceA, 0)
	if len(history.Commits) != 5 {
		t.Fatalf("提交历史应有 5 条，得到 %+v", history)
	}
	var seqs []int64
	for _, c := range history.Commits {
		seqs = append(seqs, c.Seq)
	}
	for i, seq := range seqs {
		if seq != int64(i+1) {
			t.Fatalf("提交序号应为 1..5 连续，得到 %v", seqs)
		}
	}
	if history.Commits[3].RequestID != "walk-a-concurrent" || history.Commits[4].RequestID != "walk-b-reconciled" {
		t.Fatalf("同一行的两条并发修改都应在历史里，顺序为先 A 后 B：%+v", history.Commits)
	}
	if history.Head != 5 {
		t.Fatalf("拉取到的 head 应为 5，得到 %d", history.Head)
	}
	t.Logf("步骤 6：拉取 5 条历史，序号连续；同一行的两次修改都在，后到达的 B 排在第 5 条")

	// ---- 6. 丢失响应之后用同一个 request_id 原样重推：不重复追加 ----
	if code, head := push(deviceB, 5, reconciled); code != http.StatusOK || head != 5 {
		t.Fatalf("重复 request_id 应被跳过：%d head=%d", code, head)
	}
	if page := pull(deviceA, 0); len(page.Commits) != 5 {
		t.Fatalf("重试不应追加提交：%+v", page)
	}
	t.Logf("步骤 7：设备 B 用同一个 request_id 重推，head 仍为 5，历史仍为 5 条")

	// ---- 7. 附件按内容寻址：设备 A 上传之后设备 B 能按哈希补齐 ----
	data := []byte("walkthrough-attachment")
	sha := blobSHA(data)
	if code := h.json("HEAD", "/v1/blobs/"+sha, deviceB, nil, nil); code != http.StatusNotFound {
		t.Fatalf("设备 B 上传前不应看到附件：%d", code)
	}
	resp := h.do("PUT", "/v1/blobs/"+sha, deviceA, bytes.NewReader(data), nil)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("设备 A 上传附件：%d", resp.StatusCode)
	}
	resp = h.do("HEAD", "/v1/blobs/"+sha, deviceB, nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("设备 B 应看到同一账号已上传的附件：%d", resp.StatusCode)
	}
	resp = h.do("GET", "/v1/blobs/"+sha, deviceB, nil, nil)
	if got := testutilReadBody(t, resp); !bytes.Equal(got, data) {
		t.Fatalf("设备 B 下载的附件不一致：%q", got)
	}
	t.Logf("步骤 8：设备 A 上传附件，设备 B 按哈希检查并取回原始字节")

	// ---- 8. 清空云端数据之后，两台设备从 0 重新上传基线 ----
	if code := h.json("DELETE", "/v1/sync/commits", deviceA, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("清空提交：%d", code)
	}
	if page := pull(deviceB, 0); len(page.Commits) != 0 || page.Head != 0 {
		t.Fatalf("清空之后两台设备都应看到空序列：%+v", page)
	}
	rebased := walkCommit("walk-a-rebaseline", "device-a", "system", "首次同步基线", map[string]any{
		"table": "plan_item", "row_key": "row-z", "op": "insert",
		"after": map[string]any{"title": "重新开始"},
	})
	if code, head := push(deviceA, 0, rebased); code != http.StatusOK || head != 1 {
		t.Fatalf("清空后重新上传基线：%d head=%d", code, head)
	}
	t.Logf("步骤 9：DELETE /v1/sync/commits 之后 head=0，设备 A 重新上传基线，head=1")
}
