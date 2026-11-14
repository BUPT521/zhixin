package auth

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAuthenticationRateLimits(t *testing.T) {
	svc := NewService(NewMemoryStore(), time.Hour, 2*time.Hour)
	h := NewHandler(svc, slog.New(slog.NewTextHandler(io.Discard, nil)), 1024)
	now := time.Now()
	h.limits.now = func() time.Time { return now }
	call := func(fn http.HandlerFunc, address, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest("POST", "/", strings.NewReader(body))
		request.RemoteAddr = address
		request.Header.Set("X-Forwarded-For", "198.51.100.10")
		w := httptest.NewRecorder()
		fn(w, request)
		return w
	}
	assertLimited := func(w *httptest.ResponseRecorder, retry string) {
		t.Helper()
		if w.Code != http.StatusTooManyRequests ||
			w.Header().Get("Retry-After") != retry ||
			w.Header().Get("Content-Type") != "application/problem+json" ||
			!strings.Contains(w.Body.String(), `"code":"rate_limited"`) {
			t.Fatalf("limiter response: %d %v %s", w.Code, w.Header(), w.Body)
		}
	}
	const first = "192.0.2.1:1234"
	const second = "192.0.2.2:1234"
	for i := 0; i < 10; i++ {
		if w := call(h.login, first, "{}"); w.Code != http.StatusUnauthorized {
			t.Fatalf("login %d: %d", i, w.Code)
		}
	}
	assertLimited(call(h.login, "192.0.2.1:5678", "{}"), "6")
	if w := call(h.login, second, "{}"); w.Code != http.StatusUnauthorized {
		t.Fatalf("different source: %d", w.Code)
	}
	now = now.Add(6 * time.Second)
	if w := call(h.login, first, "{}"); w.Code != http.StatusUnauthorized {
		t.Fatalf("after refill: %d", w.Code)
	}
	for i := 0; i < 3; i++ {
		if w := call(h.register, first, "{}"); w.Code != http.StatusBadRequest {
			t.Fatalf("registration %d: %d", i, w.Code)
		}
	}
	assertLimited(call(h.register, first, "{}"), "20")

	for i := 0; i < 30; i++ {
		if w := call(h.refresh, first, `{"refresh_token":"unknown"}`); w.Code != http.StatusUnauthorized {
			t.Fatalf("unknown refresh %d: %d", i, w.Code)
		}
	}
	assertLimited(call(h.refresh, first, `{"refresh_token":"unknown"}`), "2")

	tokens, err := svc.Register(t.Context(), "learner@example.test", "test-password", "fixture")
	if err != nil {
		t.Fatal(err)
	}
	refresh := func(address string) *httptest.ResponseRecorder {
		return call(h.refresh, address, `{"refresh_token":"`+tokens.RefreshToken+`"}`)
	}
	for i := 0; i < 12; i++ {
		w := refresh(second)
		if w.Code != http.StatusOK {
			t.Fatalf("rotation %d: %s", i, w.Body)
		}
		if err := json.Unmarshal(w.Body.Bytes(), &tokens); err != nil {
			t.Fatal(err)
		}
	}
	assertLimited(refresh("192.0.2.3:4321"), "5")
	if _, err := svc.Authenticate(context.Background(), tokens.AccessToken); err != nil {
		t.Fatalf("throttled refresh invalidated session: %v", err)
	}
	now = now.Add(5 * time.Second)
	if w := refresh(second); w.Code != http.StatusOK {
		t.Fatalf("refresh after refill: %d %s", w.Code, w.Body)
	}
}
