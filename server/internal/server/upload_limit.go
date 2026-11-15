package server

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// withUploadLimit limits backup and attachment uploads per account. Both
// handlers spool the request body to a temporary file, so one account must not
// be able to fill the disk by repeating them.
func withUploadLimit(next http.Handler, limiter *ratelimit.Limiter) http.Handler {
	if limiter == nil {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isUploadRoute(r.Method, r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		principal, ok := auth.PrincipalFrom(r.Context())
		if !ok {
			next.ServeHTTP(w, r)
			return
		}
		if delay := limiter.Take("upload:" + principal.UserID); delay > 0 {
			w.Header().Set("Retry-After", strconv.FormatInt(delay, 10))
			httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "too many uploads, retry later")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func isUploadRoute(method, path string) bool {
	if method == http.MethodPost && path == "/v1/backups" {
		return true
	}
	return method == http.MethodPut && strings.HasPrefix(path, "/v1/blobs/")
}
