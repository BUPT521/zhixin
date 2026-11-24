package auth

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// failingStore 让会话查询失败，用来区分“令牌无效”与“存储不可用”。
type failingStore struct{ *MemoryStore }

func (failingStore) SessionByAccessHash(context.Context, string) (Session, error) {
	return Session{}, errors.New("database is down")
}

type problem struct {
	Status    int    `json:"status"`
	Code      string `json:"code"`
	RequestID string `json:"request_id"`
}

// newAuthedHandler 接一条受保护路由与一条公开路由，用来单看中间件的状态码与
// 响应体；业务处理器的用例由各包自己负责。
func newAuthedHandler(t *testing.T, store Store) (http.Handler, *Service) {
	t.Helper()
	svc := NewService(store, time.Hour, time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/me", func(w http.ResponseWriter, r *http.Request) {
		p := MustPrincipal(r.Context())
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"user_id": p.UserID})
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	// 模型路由用来核对密钥的作用域：密钥只在这里被放行。
	mux.HandleFunc("POST /v1/llm/responses", func(w http.ResponseWriter, r *http.Request) {
		p := MustPrincipal(r.Context())
		httpx.WriteJSON(w, http.StatusOK, map[string]string{"user_id": p.UserID, "key_id": p.KeyID})
	})
	return httpx.Chain(Middleware(svc, log)(mux), httpx.RequestID), svc
}

// serve 发一次请求；authorization 为空表示不带 Authorization 头。
func serve(t *testing.T, h http.Handler, method, path, authorization string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decodeProblem(t *testing.T, rec *httptest.ResponseRecorder) problem {
	t.Helper()
	var p problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode problem: %v", err)
	}
	return p
}

func TestMiddlewareAcceptsValidToken(t *testing.T) {
	h, svc := newAuthedHandler(t, NewMemoryStore())
	tok, err := svc.Register(context.Background(), "a@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}

	rec := serve(t, h, http.MethodGet, "/v1/me", "Bearer "+tok.AccessToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("valid token: %d", rec.Code)
	}
	var body struct {
		UserID string `json:"user_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.UserID != tok.UserID {
		t.Fatalf("principal = %q, want %q", body.UserID, tok.UserID)
	}

	// 公开路由不要求令牌。
	if rec := serve(t, h, http.MethodGet, "/healthz", ""); rec.Code != http.StatusOK {
		t.Fatalf("public route: %d", rec.Code)
	}
}

func TestMiddlewareRejectsInvalidToken(t *testing.T) {
	h, svc := newAuthedHandler(t, NewMemoryStore())
	tok, err := svc.Register(context.Background(), "a@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name          string
		authorization string
	}{
		{"missing token", ""},
		{"unknown token", "Bearer no-such-token"},
		{"wrong scheme", "Basic " + tok.AccessToken},
		{"empty bearer", "Bearer "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := serve(t, h, http.MethodGet, "/v1/me", tc.authorization)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status %d, want 401", rec.Code)
			}
			p := decodeProblem(t, rec)
			if p.Code != string(httpx.CodeUnauthorized) {
				t.Fatalf("code %q", p.Code)
			}
			if p.RequestID == "" || p.RequestID != rec.Header().Get("X-Request-Id") {
				t.Fatalf("problem request_id %q, header %q", p.RequestID, rec.Header().Get("X-Request-Id"))
			}
			if got := rec.Header().Get("WWW-Authenticate"); got == "" {
				t.Fatal("401 must carry WWW-Authenticate")
			}
		})
	}

	// 过期的访问令牌同样是 401：这是过期，不是存储故障。
	now := svc.now
	svc.now = func() time.Time { return now().Add(2 * time.Hour) }
	defer func() { svc.now = now }()
	if rec := serve(t, h, http.MethodGet, "/v1/me", "Bearer "+tok.AccessToken); rec.Code != http.StatusUnauthorized {
		t.Fatalf("expired token: %d, want 401", rec.Code)
	}
}

// fakeActivity 记录中间件报告过的账号活跃；去重是记录器的职责，不在中间件里。
type fakeActivity struct {
	ids []string
	err error
}

func (f *fakeActivity) RecordUserActive(_ context.Context, userID string) error {
	f.ids = append(f.ids, userID)
	return f.err
}

// TestMiddlewareRecordsActivityAfterAuth 核对登录用户的活跃只统计鉴权成功的请求：
// 未带令牌的请求不记录，记录失败也不影响这次请求。
func TestMiddlewareRecordsActivityAfterAuth(t *testing.T) {
	h, svc := newAuthedHandler(t, NewMemoryStore())
	activity := &fakeActivity{}
	svc.SetActivityRecorder(activity)
	tok, err := svc.Register(context.Background(), "a@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}

	if rec := serve(t, h, http.MethodGet, "/v1/me", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous request: %d", rec.Code)
	}
	if len(activity.ids) != 0 {
		t.Fatalf("未鉴权的请求不应记录活跃：%v", activity.ids)
	}

	for i := 0; i < 2; i++ {
		if rec := serve(t, h, http.MethodGet, "/v1/me", "Bearer "+tok.AccessToken); rec.Code != http.StatusOK {
			t.Fatalf("valid request %d: %d", i+1, rec.Code)
		}
	}
	if len(activity.ids) != 2 || activity.ids[0] != tok.UserID {
		t.Fatalf("两个已鉴权请求都应记录活跃：%v", activity.ids)
	}

	activity.err = errors.New("stats store is down")
	if rec := serve(t, h, http.MethodGet, "/v1/me", "Bearer "+tok.AccessToken); rec.Code != http.StatusOK {
		t.Fatalf("活跃记录失败不应让请求失败：%d", rec.Code)
	}
}

// TestMiddlewareReportsStoreFailureAs500 守住 401 与 500 的分界：令牌本身没问题，
// 存储查不动时必须回 500，而不是让客户端以为登录过期、白白清掉本地令牌。
func TestMiddlewareReportsStoreFailureAs500(t *testing.T) {
	h, _ := newAuthedHandler(t, failingStore{NewMemoryStore()})

	rec := serve(t, h, http.MethodGet, "/v1/me", "Bearer some-access-token")
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status %d, want 500", rec.Code)
	}
	p := decodeProblem(t, rec)
	if p.Code != string(httpx.CodeInternal) {
		t.Fatalf("code %q, want internal", p.Code)
	}
	if p.RequestID == "" {
		t.Fatal("500 must carry request_id")
	}
	if got := rec.Header().Get("Content-Type"); got != "application/problem+json" {
		t.Fatalf("content type %q", got)
	}
}

// TestNeedsAuthTreatsHeadAsGet 守住 HEAD 不绕过鉴权：标准库的 GET 路由也接
// HEAD，以前 HEAD /v1/llm/quota 会跳过令牌校验，落进处理器后 panic 成 500。
func TestNeedsAuthTreatsHeadAsGet(t *testing.T) {
	for _, path := range []string{"/v1/llm/quota", "/v1/me", "/v1/backups", "/v1/blobs/abc"} {
		if !needsAuth("HEAD", path) {
			t.Fatalf("HEAD %s 应当要求令牌", path)
		}
	}
	if needsAuth("HEAD", "/v1/app/releases") || needsAuth("HEAD", "/healthz") {
		t.Fatal("公开路由的 HEAD 不需要令牌")
	}
}

// TestMiddlewareKeyIsScopedToModels 核对模型代理密钥的两个边界：模型路由接受
// 密钥并带上 KeyID，账号与数据路由回 403 key_scope_denied；撤销之后立即回到
// 401，与访问令牌的失效同一口径（ADR-0063）。
func TestMiddlewareKeyIsScopedToModels(t *testing.T) {
	h, svc := newAuthedHandler(t, NewMemoryStore())
	ctx := context.Background()
	tok, err := svc.Register(ctx, "key@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	key, secret, err := svc.CreateAPIKey(ctx, Principal{UserID: tok.UserID}, "脚本")
	if err != nil {
		t.Fatalf("create key: %v", err)
	}

	rec := serve(t, h, http.MethodPost, "/v1/llm/responses", "Bearer "+secret)
	if rec.Code != http.StatusOK {
		t.Fatalf("模型路由应接受密钥，得到 %d：%s", rec.Code, rec.Body.String())
	}
	var body struct {
		UserID string `json:"user_id"`
		KeyID  string `json:"key_id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.UserID != tok.UserID || body.KeyID != key.ID {
		t.Fatalf("调用者不对：%+v", body)
	}

	rec = serve(t, h, http.MethodGet, "/v1/me", "Bearer "+secret)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("账号路由应拒绝密钥，得到 %d：%s", rec.Code, rec.Body.String())
	}
	if p := decodeProblem(t, rec); p.Code != string(httpx.CodeKeyScopeDenied) {
		t.Fatalf("错误码应为 key_scope_denied，得到 %+v", p)
	}

	if err := svc.RevokeAPIKey(ctx, Principal{UserID: tok.UserID}, key.ID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if rec := serve(t, h, http.MethodPost, "/v1/llm/responses", "Bearer "+secret); rec.Code != http.StatusUnauthorized {
		t.Fatalf("撤销之后应回 401，得到 %d", rec.Code)
	}
}

// countingActivity 记下 RecordUserActive 被调用的次数。
type countingActivity struct{ calls int }

func (c *countingActivity) RecordUserActive(context.Context, string) error {
	c.calls++
	return nil
}

// TestMiddlewareKeyRequestsSkipActivity 核对日活口径：密钥请求不计入账号活跃，
// 访问令牌请求照常记录（ADR-0063）。
func TestMiddlewareKeyRequestsSkipActivity(t *testing.T) {
	h, svc := newAuthedHandler(t, NewMemoryStore())
	activity := &countingActivity{}
	svc.SetActivityRecorder(activity)
	ctx := context.Background()
	tok, err := svc.Register(ctx, "quiet@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	_, secret, err := svc.CreateAPIKey(ctx, Principal{UserID: tok.UserID}, "脚本")
	if err != nil {
		t.Fatalf("create key: %v", err)
	}

	if rec := serve(t, h, http.MethodPost, "/v1/llm/responses", "Bearer "+secret); rec.Code != http.StatusOK {
		t.Fatalf("模型路由应接受密钥，得到 %d", rec.Code)
	}
	if activity.calls != 0 {
		t.Fatalf("密钥请求不应计入日活，记录 %d 次", activity.calls)
	}
	if rec := serve(t, h, http.MethodGet, "/v1/me", "Bearer "+tok.AccessToken); rec.Code != http.StatusOK {
		t.Fatalf("令牌请求应通过，得到 %d", rec.Code)
	}
	if activity.calls != 1 {
		t.Fatalf("访问令牌请求应记一次活跃，记录 %d 次", activity.calls)
	}
}
