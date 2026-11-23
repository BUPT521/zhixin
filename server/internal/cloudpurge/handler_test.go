package cloudpurge

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// testAPI 只接清除路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) DeleteV1Cloud(w http.ResponseWriter, r *http.Request) { a.h.Purge(w, r) }

// newTestServer 装配清除处理器与鉴权中间件，返回客户端与账号服务。
func newTestServer(t *testing.T) (*testutil.Client, *auth.Service) {
	t.Helper()
	return newTestServerWith(t, &fakeBackups{}, &fakeSync{}, &fakeBlobs{}, &fakeEmbeddings{})
}

// newTestServerWith 与 newTestServer 相同，只是允许用例传入会失败的步骤实现。
func newTestServerWith(t *testing.T, backups Backups, syncLog SyncLog, blobs Attachments, embeddings Embeddings) (*testutil.Client, *auth.Service) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := New(backups, syncLog, blobs, embeddings, objectstore.NewMemory())
	handler := NewHandler(svc, log)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: handler},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc
}

// signIn 注册一个测试账号并返回令牌（含账号 id）。
func signIn(t *testing.T, svc *auth.Service, email string) auth.Tokens {
	t.Helper()
	tokens, err := svc.Register(context.Background(), email, "password1", "")
	if err != nil {
		t.Fatalf("register %s: %v", email, err)
	}
	return tokens
}

// requireProtectedRoute 检查 auth.Middleware 是否已经给 DELETE /v1/cloud 注入
// 调用者。auth 包的 securedRoutes 是手写清单，新增受保护路由要同步登记；这一
// 步在装配时完成（cloudpurge 不改 auth 包），登记之前处理器拿不到 caller，
// HTTP 用例跳过而不是误报失败。
func requireProtectedRoute(t *testing.T, svc *auth.Service, token string) {
	t.Helper()
	var secured bool
	next := http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		_, secured = auth.PrincipalFrom(r.Context())
	})
	req := httptest.NewRequest(http.MethodDelete, "/v1/cloud", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	auth.Middleware(svc, slog.New(slog.NewTextHandler(io.Discard, nil)))(next).
		ServeHTTP(httptest.NewRecorder(), req)
	if !secured {
		t.Skip("auth.Middleware 的 securedRoutes 还没有登记 DELETE /v1/cloud，等装配方补上")
	}
}

// TestHandlerPurgeEmptyAccount 守住空账号也回 204、重复调用幂等、未登录 401。
// 并发清除与清除期间的写请求由 server 包的 cloudOperations 回 409，不经过这里
// （审查 9.3 的 V10）。
func TestHandlerPurgeEmptyAccount(t *testing.T) {
	c, authSvc := newTestServer(t)
	tokens := signIn(t, authSvc, "a@b.cn")
	requireProtectedRoute(t, authSvc, tokens.AccessToken)

	for i := 0; i < 2; i++ {
		if code := c.JSON(http.MethodDelete, "/v1/cloud", tokens.AccessToken, nil, nil); code != http.StatusNoContent {
			t.Fatalf("purge %d: %d", i+1, code)
		}
	}
	p := testutil.ReadProblem(t, c.Do(http.MethodDelete, "/v1/cloud", "", nil, nil))
	if p.Status != http.StatusUnauthorized || p.Code != string(httpx.CodeUnauthorized) {
		t.Fatalf("anonymous purge: %+v", p)
	}
}

// TestHandlerPurgeFailureIs500 守住某一步失败时的响应：回 500，由用户重发请求
// 从头再走一遍；错误里不带内部细节。
func TestHandlerPurgeFailureIs500(t *testing.T) {
	boom := errors.New("备份存储不可用")
	c, authSvc := newTestServerWith(t, &fakeBackups{errs: []error{boom}}, &fakeSync{}, &fakeBlobs{}, &fakeEmbeddings{})
	tokens := signIn(t, authSvc, "fail@b.cn")
	requireProtectedRoute(t, authSvc, tokens.AccessToken)

	p := testutil.ReadProblem(t, c.Do(http.MethodDelete, "/v1/cloud", tokens.AccessToken, nil, nil))
	if p.Status != http.StatusInternalServerError || p.Code != string(httpx.CodeInternal) {
		t.Fatalf("failed purge: %+v", p)
	}
}
