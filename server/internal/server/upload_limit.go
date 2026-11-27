package server

import (
	"net/http"

	"golang.org/x/sync/semaphore"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
)

// temporaryUploadBudget reserves the maximum spool size before reading each
// upload and holds it until the handler has removed the temporary file.
func temporaryUploadBudget(budgetBytes, backupBytes, attachmentBytes int64) api.MiddlewareFunc {
	budget := semaphore.NewWeighted(budgetBytes)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var size int64
			switch r.Pattern {
			case "POST /v1/backups":
				size = backupBytes
			case "PUT /v1/blobs/{sha256}":
				size = attachmentBytes
			default:
				next.ServeHTTP(w, r)
				return
			}
			if !budget.TryAcquire(size) {
				httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "temporary upload storage is busy")
				return
			}
			defer budget.Release(size)
			next.ServeHTTP(w, r)
		})
	}
}

// uploadLimit 在鉴权后按账号限制备份、附件与同步提交的写入频率。
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

// syncConcurrency limits the total number of pages or pushes held in memory.
func syncConcurrency(maxConcurrent int64) api.MiddlewareFunc {
	slots := semaphore.NewWeighted(maxConcurrent)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.Pattern {
			case "GET /v1/sync/commits", "POST /v1/sync/commits":
				if !slots.TryAcquire(1) {
					httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "sync capacity is busy")
					return
				}
				defer slots.Release(1)
			}
			next.ServeHTTP(w, r)
		})
	}
}
