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
