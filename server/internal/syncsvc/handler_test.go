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
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

const (
	// testSchemaVersion 与服务端接受的客户端 schema 版本一致（server.ClientSchemaVersion）。
	testSchemaVersion = 27
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
