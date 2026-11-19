// Package admin 是管理后台的入口：/admin/ 下的静态页面与 /admin/v1/ 管理接口
// 的令牌校验。管理接口的处理器在各业务包里（目前只有 llmproxy 的模型来源与
// 路由），这里不碰业务数据。
//
// 管理令牌来自 ZHIXIN_ADMIN_TOKEN，为空时整个 /admin 返回 404，看不出后台是否
// 存在。令牌与账号体系无关：服务器只有一位管理员（docs/04 D7），单独的令牌
// 比在账号上加角色简单，也不会因为某个账号被盗而暴露后台。
package admin

import (
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"io/fs"
	"net/http"
	"strconv"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

//go:embed ui
var uiFiles embed.FS

// Options 配置管理入口。
type Options struct {
	// Token 是管理令牌；为空时关闭后台。
	Token string
	// Limiter 限制令牌校验失败的次数，按来源地址计；nil 表示不限。
	Limiter *ratelimit.Limiter
	// ClientHost 取来源地址，与其余限流同一口径（ZHIXIN_TRUSTED_PROXIES）。
	ClientHost func(*http.Request) string
}

// Middleware 拦住 /admin 开头的请求：后台关闭时一律 404；/admin/v1/ 下的接口
// 要求 Authorization: Bearer <管理令牌>，错误的令牌计入失败限流，超限之后这个
// 地址的所有管理请求都先返回 429。页面本身不含
// 任何数据，不需要令牌，打开之后由页面向接口出示令牌。
func Middleware(opt Options) func(http.Handler) http.Handler {
	want := sha256.Sum256([]byte(opt.Token))
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, path, matched := strings.Cut(r.Pattern, " ")
			if !matched {
				path = r.URL.Path
			}
			if path != "/admin" && !strings.HasPrefix(path, "/admin/") {
				next.ServeHTTP(w, r)
				return
			}
			if opt.Token == "" {
				httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
				return
			}
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("X-Frame-Options", "DENY")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Header().Set("Referrer-Policy", "no-referrer")
			if strings.HasPrefix(path, "/admin/v1/") {
				tooMany := func(delay int64) {
					w.Header().Set("Retry-After", strconv.FormatInt(delay, 10))
					httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "too many failed admin attempts")
				}
				key := "admin:" + opt.ClientHost(r)
				// 已经超限的地址连正确的令牌也先挡住，猜测者不能靠成功与否区分。
				if opt.Limiter != nil {
					if delay := opt.Limiter.WouldBlock(key); delay > 0 {
						tooMany(delay)
						return
					}
				}
				got, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
				sum := sha256.Sum256([]byte(got))
				if got == "" || subtle.ConstantTimeCompare(sum[:], want[:]) != 1 {
					if opt.Limiter != nil {
						if delay := opt.Limiter.Take(key); delay > 0 {
							tooMany(delay)
							return
						}
					}
					w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin-admin"`)
					httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "admin token is missing or wrong")
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// RegisterUI 把后台页面挂到 mux 上。页面、脚本与样式都编进可执行文件，不依赖
// 外部 CDN，部署仍然只有一个文件。
func RegisterUI(mux *http.ServeMux, guard func(http.Handler) http.Handler) {
	sub, err := fs.Sub(uiFiles, "ui")
	if err != nil {
		panic(err)
	}
	serve := func(name, contentType string) http.HandlerFunc {
		body, err := fs.ReadFile(sub, name)
		if err != nil {
			panic(err)
		}
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", contentType)
			w.Header().Set("Content-Security-Policy",
				"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
			_, _ = w.Write(body)
		}
	}
	mux.Handle("GET /admin", guard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/admin/", http.StatusMovedPermanently)
	})))
	mux.Handle("GET /admin/{$}", guard(serve("index.html", "text/html; charset=utf-8")))
	mux.Handle("GET /admin/app.js", guard(serve("app.js", "text/javascript; charset=utf-8")))
	mux.Handle("GET /admin/app.css", guard(serve("app.css", "text/css; charset=utf-8")))
}
