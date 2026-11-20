package syncsvc

import (
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
	testSchemaVersion = 29
	testMaxJSON       = 1 << 20
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) GetV1SyncHead(w http.ResponseWriter, r *http.Request) { a.h.Head(w, r) }

func (a testAPI) GetV1SyncCommits(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	a.h.Pull(w, r, params)
}

func (a testAPI) PostV1SyncCommits(w http.ResponseWriter, r *http.Request) { a.h.Push(w, r) }

func (a testAPI) DeleteV1SyncCommits(w http.ResponseWriter, r *http.Request) { a.h.Reset(w, r) }

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
