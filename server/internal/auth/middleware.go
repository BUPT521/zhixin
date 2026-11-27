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
// 鉴权中间件在认证之后调用它；装配处与测试也可以在鉴权之前用同一个入口注入
// 调用者，不必再各自拼上下文。
func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey, p)
}

// Middleware 对除公开操作以外的已匹配路由校验 Bearer 令牌，并把调用者放进
// 请求上下文。
//
// 凭据有两种，靠固定前缀、长度与校验码区分：zx_ 开头的是模型代理密钥，其余是访问
// 令牌。密钥只接受 /v1/llm 下的模型接口，访问其余受保护路由时回 403
// key_scope_denied；密钥本身不参与登录，也不持有学习数据（ADR-0063）。
//
// 是否要求令牌只由 r.Pattern 决定：生成的路由处理器里，mux 已经把注册模式
// （例如 "GET /v1/me"）写进 r.Pattern。编码路径先归一再匹配，HEAD 落到 GET
// 路由时同样带 "GET ..."，所以这里不需要再自己拼路径表，也不会被写法差异绕过。
// 没有匹配到契约路由的请求不会进入生成的处理器，mux 的兜底处理器直接回 404，
// 这条中间件只在已匹配的路由里运行。
//
// 只有 ErrInvalidToken（缺失、过期、已轮换掉、已撤销）回 401；存储不可用等其余
// 错误走 WriteInternal，回 500 并记日志，不再把数据库故障报成“令牌无效”。
func Middleware(svc *Service, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !routepolicy.RequiresAuth(r.Pattern) {
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
			case p.KeyID != "" && !routepolicy.AllowsKey(r.Pattern):
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
