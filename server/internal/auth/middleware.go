package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
)

// WithPrincipal 把调用者放进请求上下文，供 PrincipalFrom 与 MustPrincipal 取回。
// 鉴权中间件在生成路由的中间件链里被调用，装配处与测试也可以用它在鉴权之前
// 注入一个调用者。
func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return withPrincipal(ctx, p)
}

// Middleware 对除公开操作以外的已匹配路由校验 Bearer 令牌，并把调用者放进
// 请求上下文。
//
// 凭据有两种，靠固定前缀区分：zx_ 开头的是模型代理密钥，其余是访问令牌。密钥
// 只接受 /v1/llm 下的模型接口，访问其余受保护路由时回 403 key_scope_denied；
// 密钥本身不参与登录，也不持有学习数据（ADR-0063）。
//
// 是否要求令牌只由 r.Pattern 决定：生成的路由处理器里，mux 已经把注册模式
// （例如 "GET /v1/me"）写进 r.Pattern。编码路径先归一再匹配，HEAD 落到 GET
// 路由时同样带 "GET ..."，所以这里不需要再自己拼路径表，也不会被写法差异绕过。
// 没有匹配到契约路由的请求不会进入生成的处理器，mux 的兜底处理器直接回 404。
//
// 只有 ErrInvalidToken（缺失、过期、已轮换掉、已撤销）回 401；存储不可用等其余
// 错误走 WriteInternal，回 500 并记日志，不再把数据库故障报成“令牌无效”。
func Middleware(svc *Service, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !requiresAuth(r) {
				next.ServeHTTP(w, r)
				return
			}
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin"`)
				httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "missing bearer token")
				return
			}
			var p Principal
			var err error
			if LooksLikeAPIKey(token) {
				p, err = svc.AuthenticateAPIKey(r.Context(), token)
			} else {
				p, err = svc.Authenticate(r.Context(), token)
			}
			switch {
			case errors.Is(err, ErrInvalidToken):
				w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin", error="invalid_token"`)
				httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "access token is invalid, expired or revoked")
			case err != nil:
				httpx.WriteInternal(w, r, log, err)
			case p.KeyID != "" && !allowsKey(r):
				// 密钥只做模型调用；数据接口与管理接口都要求登录令牌。
				httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeKeyScopeDenied,
					"api keys may only call the model endpoints")
			default:
				// 只用密钥的脚本请求不计入日活：日活按本人打开应用计算，定时任务
				// 不应该抬高留存指标（ADR-0063）。活跃统计本身是尽力而为，存储
				// 故障只记日志，不让这次请求失败。
				if p.KeyID == "" {
					if err := svc.RecordActivity(r.Context(), p.UserID); err != nil {
						log.Warn("record user activity",
							slog.String("request_id", httpx.RequestIDFrom(r.Context())),
							slog.String("error", err.Error()),
						)
					}
				}
				next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
			}
		})
	}
}

// allowsKey 报告这次请求是否在密钥的作用域内。正常装配下看 r.Pattern；中间件被
// 装在 mux 外层时（共享测试装配仍是这种位置）r.Pattern 为空，按方法与路径精确
// 匹配，密钥允许的五条路由都没有路径参数，因此不会误放行带参数的路径。
func allowsKey(r *http.Request) bool {
	if r.Pattern != "" {
		return routepolicy.AllowsKey(r.Pattern)
	}
	return routepolicy.AllowsKey(methodPattern(r.Method, r.URL.Path))
}

// requiresAuth 报告这次请求是否要求 Bearer。
//
// 正常装配下中间件在生成路由的中间件链里，mux 已经把注册模式写进 r.Pattern，
// 判定只看这张表。r.Pattern 为空说明中间件被装在了 mux 外层：共享的测试装配
// （testutil.NewServer）与旧的装配方式仍是这种位置，此时按 URL.Path 默认拒绝，
// 只有契约里明确公开的操作按原路径放行，编码路径等写法差异一律要求令牌，宁可
// 更严也不放行。生产装配里 r.Pattern 恒非空，走不到这一支。
func requiresAuth(r *http.Request) bool {
	if r.Pattern != "" {
		return routepolicy.RequiresAuth(r.Pattern)
	}
	return !routepolicy.IsPublic(methodPattern(r.Method, r.URL.Path))
}

// methodPattern 把方法与被请求的路径拼成契约写法，HEAD 按 GET 判断：标准库的
// GET 路由也接 HEAD。
func methodPattern(method, path string) string {
	if method == http.MethodHead {
		method = http.MethodGet
	}
	return method + " " + path
}

// needsAuth 保留给包内测试核对“HEAD 按 GET 判断、公开路由不要求令牌”的口径；
// 实际判定见 requiresAuth。
func needsAuth(method, path string) bool {
	return !routepolicy.IsPublic(methodPattern(method, path))
}
