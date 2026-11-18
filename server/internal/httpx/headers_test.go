package httpx

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// serveThroughSecurityHeaders 把一次请求交给套了 SecurityHeaders 的处理器。
func serveThroughSecurityHeaders(t *testing.T, handler http.HandlerFunc) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	SecurityHeaders(handler).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	return rec
}

func TestSecurityHeadersDefaultsToNoStore(t *testing.T) {
	rec := serveThroughSecurityHeaders(t, func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	if got := rec.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("X-Content-Type-Options = %q", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("默认 Cache-Control = %q，想要 no-store", got)
	}
}

func TestCacheableOverridesTheDefault(t *testing.T) {
	rec := serveThroughSecurityHeaders(t, func(w http.ResponseWriter, _ *http.Request) {
		Cacheable(w, 60)
		WriteJSON(w, http.StatusOK, map[string]string{"releases": "none"})
	})
	if got := rec.Header().Get("Cache-Control"); got != "public, max-age=60" {
		t.Fatalf("Cache-Control = %q，想要 public, max-age=60", got)
	}
	if got := rec.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Fatalf("可缓存响应也要带 nosniff，得到 %q", got)
	}
}

// TestHandlersCannotSetCacheControlDirectly 守住“默认 no-store 不能被随便覆盖”：
// 处理器直接写 Cache-Control 不算数，必须经过 Cacheable。
func TestHandlersCannotSetCacheControlDirectly(t *testing.T) {
	rec := serveThroughSecurityHeaders(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "public, max-age=9999")
		WriteJSON(w, http.StatusOK, map[string]string{"account": "secret"})
	})
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q，想要 no-store", got)
	}
}

// TestCacheableDoesNotCacheErrors 核对即使处理器声明了可缓存，非 2xx 的响应也会
// 退回 no-store：panic 由外层恢复成 500 时不能带上 public 缓存头。
func TestCacheableDoesNotCacheErrors(t *testing.T) {
	rec := serveThroughSecurityHeaders(t, func(w http.ResponseWriter, r *http.Request) {
		Cacheable(w, 60)
		WriteProblem(w, r, http.StatusInternalServerError, CodeInternal, "")
	})
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("错误响应的 Cache-Control = %q，想要 no-store", got)
	}
}

// TestSecurityHeadersKeepStreaming 核对换了包装之后流式响应仍然能刷新，且第一次
// 刷新之前默认响应头已经写好。
func TestSecurityHeadersKeepStreaming(t *testing.T) {
	rec := serveThroughSecurityHeaders(t, func(w http.ResponseWriter, _ *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Error("处理器拿不到 http.Flusher，流式响应会断")
			return
		}
		_, _ = w.Write([]byte("data: one\n\n"))
		flusher.Flush()
	})
	if !rec.Flushed {
		t.Fatal("Flush 没有生效")
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("流式响应的 Cache-Control = %q，想要 no-store", got)
	}
	if rec.Body.String() != "data: one\n\n" {
		t.Fatalf("响应体 = %q", rec.Body.String())
	}
}
