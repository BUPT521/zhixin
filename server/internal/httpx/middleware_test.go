package httpx

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// patternRecorder 模拟访问日志里的 statusRecorder：只关心 RecordPattern 送来的
// 注册模式。
type patternRecorder struct {
	http.ResponseWriter
	pattern string
}

func (p *patternRecorder) SetPattern(pattern string) { p.pattern = pattern }

// TestRecordPatternCrossesSecurityHeaders 守住 S19：SecurityHeaders 换上的
// cacheGuard 要把它收到的 SetPattern 转交给内层记录器。cacheGuard 只内嵌
// http.ResponseWriter 接口时类型断言失败，RecordPattern 在生产链上一次不生效，
// 访问日志只能靠外层请求上的 r.Pattern 兜底。
func TestRecordPatternCrossesSecurityHeaders(t *testing.T) {
	rec := &patternRecorder{ResponseWriter: httptest.NewRecorder()}
	handler := SecurityHeaders(RecordPattern(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})))
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	req.Pattern = "GET /v1/me"
	handler.ServeHTTP(rec, req)
	if rec.pattern != "GET /v1/me" {
		t.Fatalf("route pattern = %q，想要 GET /v1/me；SetPattern 没有穿过 cacheGuard", rec.pattern)
	}
}
