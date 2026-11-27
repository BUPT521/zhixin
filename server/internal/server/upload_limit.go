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
func temporaryUploadBudget(backupBytes, attachmentBytes int64) api.MiddlewareFunc {
	budget := semaphore.NewWeighted(1 << 30)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var size int64
			policy, _ := routepolicy.CloudWritePolicy(r.Pattern)
			switch policy.Spool {
			case routepolicy.BackupSpool:
				size = backupBytes
			case routepolicy.AttachmentSpool:
				size = attachmentBytes
			case routepolicy.NoSpool:
				next.ServeHTTP(w, r)
				return
			}
			if size <= 0 || size > 1<<30 {
				httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "upload size is outside the temporary storage budget")
				return
			}
			if !budget.TryAcquire(size) {
				httpx.TooMany(w, r, 2)
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
// 与尾斜杠不会绕开；按账号计则要求鉴权已经先跑过。限流在云端写入互斥之外，
// 未验证账号的 403 与清除期间的 409 同样消耗额度，因此这两种拒绝不能反复重试。
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
func syncConcurrency() api.MiddlewareFunc {
	slots := make(chan struct{}, 4)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.Pattern {
			case "GET /v1/sync/commits", "POST /v1/sync/commits":
				select {
				case slots <- struct{}{}:
					defer func() { <-slots }()
				default:
					httpx.TooMany(w, r, 1)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}
