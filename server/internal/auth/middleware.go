package auth

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// securedRoutes 是契约里要求 Bearer 的路径，写法与 openapi.yaml 的分段一致：
// `{name}` 匹配任意一段。只列需要鉴权的；公开路径与契约之外的路径都直接放行，
// 后者仍由 mux 的兜底处理器返回 404。
//
// 这张表放在代码里而不是从生成结果读取，是因为 oapi-codegen 的中间件拿不到当前
// 操作的 security 声明；契约增删接口时要同时改这里。
var securedRoutes = []struct {
	method  string
	pattern string
}{
	{"POST", "/v1/auth/logout"},
	{"GET", "/v1/me"},
	{"DELETE", "/v1/me"},
	{"GET", "/v1/sync/head"},
	{"GET", "/v1/sync/commits"},
	{"POST", "/v1/sync/commits"},
	{"DELETE", "/v1/sync/commits"},
	{"HEAD", "/v1/blobs/{sha256}"},
	{"GET", "/v1/blobs/{sha256}"},
	{"PUT", "/v1/blobs/{sha256}"},
	{"GET", "/v1/backups"},
	{"POST", "/v1/backups"},
	{"DELETE", "/v1/backups"},
	{"GET", "/v1/backups/{id}"},
	{"DELETE", "/v1/backups/{id}"},
	{"GET", "/v1/llm/models"},
	{"GET", "/v1/llm/quota"},
	{"POST", "/v1/llm/chat/completions"},
}

// matchPath 比较契约写法与实际路径：{name} 匹配一段非空路径。
func matchPath(pattern, path string) bool {
	want := strings.Split(strings.Trim(pattern, "/"), "/")
	got := strings.Split(strings.Trim(path, "/"), "/")
	if len(want) != len(got) {
		return false
	}
	for i, seg := range want {
		if strings.HasPrefix(seg, "{") && strings.HasSuffix(seg, "}") {
			if got[i] == "" {
				return false
			}
			continue
		}
		if seg != got[i] {
			return false
		}
	}
	return true
}

// needsAuth 报告这条请求是否落在需要 Bearer 的路由上。
func needsAuth(method, path string) bool {
	for _, rt := range securedRoutes {
		if rt.method == method && matchPath(rt.pattern, path) {
			return true
		}
	}
	return false
}

// Middleware 给需要鉴权的路由加上 Bearer 校验，并把调用者放进请求上下文。
//
// 只有 ErrInvalidToken（缺失、过期、已轮换掉）回 401；存储不可用等其余错误走
// WriteInternal，回 500 并记日志，不再把数据库故障报成“令牌无效”。
func Middleware(svc *Service, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !needsAuth(r.Method, r.URL.Path) {
				next.ServeHTTP(w, r)
				return
			}
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin"`)
				httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "missing bearer token")
				return
			}
			p, err := svc.Authenticate(r.Context(), token)
			switch {
			case errors.Is(err, ErrInvalidToken):
				w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin", error="invalid_token"`)
				httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "access token is invalid or expired")
			case err != nil:
				httpx.WriteInternal(w, r, log, err)
			default:
				next.ServeHTTP(w, r.WithContext(withPrincipal(r.Context(), p)))
			}
		})
	}
}
