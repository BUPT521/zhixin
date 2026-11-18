package server

import (
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
)

// uploadLimit 按账号限制备份与附件的上传，挂在生成路由的中间件链里、鉴权之后。
// 两个处理器都会先把请求体落到临时文件，一个账号反复上传就能把磁盘写满，所以
// 限流放在处理器之前，且只对上传操作生效。
//
// 判断用 r.Pattern 而不是路径前缀：生成代码把注册模式写进 r.Pattern，编码路径
// 与尾斜杠不会绕开；按账号计则要求鉴权已经先跑过。
func uploadLimit(limiter *ratelimit.Limiter) api.MiddlewareFunc {
	if limiter == nil {
		return func(next http.Handler) http.Handler { return next }
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !routepolicy.IsUpload(r.Pattern) {
				next.ServeHTTP(w, r)
				return
			}
			principal, ok := auth.PrincipalFrom(r.Context())
			if !ok {
				// 链上的顺序是鉴权在前、限流在后；走到这里说明装配错了。按内部
				// 错误处理，不能悄悄放过一次上传。
				panic("server: upload limit ran before authentication")
			}
			if delay := limiter.Take("upload:" + principal.UserID); delay > 0 {
				httpx.TooMany(w, r, delay)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
