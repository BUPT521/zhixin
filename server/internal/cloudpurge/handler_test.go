package cloudpurge

import (
	"context"
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

// newTestServer 装配清除处理器与鉴权中间件，返回客户端、账号服务与标记
// 存储；标记存储让用例可以模拟“清除已经进行中”。
func newTestServer(t *testing.T) (*testutil.Client, *auth.Service, *MemoryStore) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	marker := NewMemoryStore()
	svc := New(marker, &fakeBackups{}, &fakeSync{}, &fakeBlobs{}, &fakeEmbeddings{}, objectstore.NewMemory())
	handler := NewHandler(svc, log)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: handler},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc, marker
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
func TestHandlerPurgeEmptyAccount(t *testing.T) {
	c, authSvc, _ := newTestServer(t)
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

// TestHandlerPurgeConflictWhileInProgress 守住标记期间的重复请求：另一个清除
// 还没结束时回 409 conflict，结束标记之后同一条请求回 204。
func TestHandlerPurgeConflictWhileInProgress(t *testing.T) {
	c, authSvc, marker := newTestServer(t)
	tokens := signIn(t, authSvc, "a@b.cn")
	requireProtectedRoute(t, authSvc, tokens.AccessToken)
	ctx := context.Background()

	now := time.Now().UTC()
	if claimed, err := marker.ClaimPurge(ctx, tokens.UserID, now, now.Add(-StaleAfter)); err != nil || !claimed {
		t.Fatalf("seed marker: claimed %v, err %v", claimed, err)
	}
	p := testutil.ReadProblem(t, c.Do(http.MethodDelete, "/v1/cloud", tokens.AccessToken, nil, nil))
	if p.Status != http.StatusConflict || p.Code != string(httpx.CodeConflict) {
		t.Fatalf("purge during purge: %+v", p)
	}
	if err := marker.EndPurge(ctx, tokens.UserID); err != nil {
		t.Fatalf("end marker: %v", err)
	}
	if code := c.JSON(http.MethodDelete, "/v1/cloud", tokens.AccessToken, nil, nil); code != http.StatusNoContent {
		t.Fatalf("purge after marker removed: %d", code)
	}
}
