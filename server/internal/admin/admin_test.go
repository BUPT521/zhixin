package admin

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

func TestMiddlewareGuardsOnlyAdminPaths(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })
	h := Middleware(Options{
		Token:      "t0123456789abcdef0123456789abcdef",
		Limiter:    ratelimit.New(rate.Limit(0.001), 1, 0),
		ClientHost: httpx.RemoteHost,
	})(ok)
	do := func(path, token string) int {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	if code := do("/v1/me", ""); code != http.StatusTeapot {
		t.Fatalf("非后台路径应放行：%d", code)
	}
	if code := do("/administrator", ""); code != http.StatusTeapot {
		t.Fatalf("只拦 /admin 与 /admin/ 开头：%d", code)
	}
	if code := do("/admin/", ""); code != http.StatusTeapot {
		t.Fatalf("页面不需要令牌：%d", code)
	}
	if code := do("/admin/v1/models", "t0123456789abcdef0123456789abcdef"); code != http.StatusTeapot {
		t.Fatalf("正确令牌应放行：%d", code)
	}
	if code := do("/admin/v1/models", ""); code != http.StatusUnauthorized {
		t.Fatalf("缺令牌应 401：%d", code)
	}
	if code := do("/admin/v1/models", "nope"); code != http.StatusTooManyRequests {
		t.Fatalf("桶容量 1，第二次失败应 429：%d", code)
	}
	if code := do("/admin/v1/models", "t0123456789abcdef0123456789abcdef"); code != http.StatusTeapot {
		t.Fatalf("失败预算不应挡住正确令牌：%d", code)
	}
	if code := do("/admin/", ""); code != http.StatusTeapot {
		t.Fatalf("页面本身不受限流影响：%d", code)
	}
}
