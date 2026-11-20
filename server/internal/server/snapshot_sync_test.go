package server

import (
	"bytes"
	"net/http"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// TestSnapshotRoundTrip 是快照登记与清空的端到端用例：附件必须真的上传到这个
// 账号，登记之后 head 与拉取响应带出保留下界与快照指针，清除云端数据把快照与
// 保留下界一起清掉（ADR-0043）。
//
// 这条用例同时守住装配：快照归属校验要经 server.Build 注入的附件查询走到真实的
// 附件索引，漏掉 SetAttachments 时登记会返回 501。
func TestSnapshotRoundTrip(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("snap@b.cn")

	var push struct {
		Head int64 `json:"head"`
	}
	if code := h.json("POST", "/v1/sync/commits", token, map[string]any{
		"base_seq": 0,
		"commits":  []any{commitRequest("r1"), commitRequest("r2")},
	}, &push); code != http.StatusOK || push.Head != 2 {
		t.Fatalf("push: %d %+v", code, push)
	}

	snapshot := bytes.Repeat([]byte("checkpoint"), 128)
	sha := blobSHA(snapshot)
	digest := strings.Repeat("d", 64)

	// 没有上传到这个账号的哈希不能被登记。
	var p problem
	if code := h.json("PUT", "/v1/sync/snapshot", token, map[string]any{
		"seq": 2, "sha256": sha, "digest": digest,
	}, &p); code != http.StatusBadRequest || p.Code != "invalid_request" {
		t.Fatalf("未上传的附件: %d %+v", code, p)
	}

	resp := h.do("PUT", "/v1/blobs/"+sha, token, bytes.NewReader(snapshot), map[string]string{
		"Content-Type": "application/octet-stream",
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload blob: %d", resp.StatusCode)
	}
	var head api.SyncHead
	if code := h.json("PUT", "/v1/sync/snapshot", token, map[string]any{
		"seq": 2, "sha256": sha, "digest": digest,
	}, &head); code != http.StatusOK || head.Snapshot == nil || head.Snapshot.Seq != 2 ||
		head.Snapshot.Sha256 != sha || head.Snapshot.Digest != digest || head.EarliestSeq != 1 {
		t.Fatalf("登记快照: %d %+v", code, head)
	}

	// 拉取响应带同样的指针；保留期之内登记不删除提交，保留下界仍是 1。
	var page api.CommitPage
	if code := h.json("GET", "/v1/sync/commits?after=0", token, nil, &page); code != http.StatusOK ||
		len(page.Commits) != 2 || page.EarliestSeq != 1 || page.Snapshot == nil || page.Snapshot.Seq != 2 {
		t.Fatalf("拉取: %d %+v", code, page)
	}

	// 清除云端数据之后快照、保留下界与 head 一起清零，账号仍然可用。
	if code := h.json("DELETE", "/v1/cloud", token, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("clear cloud: %d", code)
	}
	var cleared api.SyncHead
	if code := h.json("GET", "/v1/sync/head", token, nil, &cleared); code != http.StatusOK ||
		cleared.Head != 0 || cleared.EarliestSeq != 1 || cleared.Snapshot != nil {
		t.Fatalf("清空之后: %d %+v", code, cleared)
	}
}
