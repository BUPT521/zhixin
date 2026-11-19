package server

import (
	"net/http"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
)

// cloudOperations lets writes for an account coexist and gives bulk deletion
// exclusive access for the full request, including object storage operations.
func cloudOperations(requireVerified bool) api.MiddlewareFunc {
	var mu sync.Mutex
	inflight := map[string]int{} // Positive for writes, -1 for exclusive deletion.
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			upload := routepolicy.IsUpload(r.Pattern)
			var exclusive bool
			switch r.Pattern {
			case "DELETE /v1/cloud", "DELETE /v1/sync/commits", "DELETE /v1/backups", "DELETE /v1/me":
				exclusive = true
			case "DELETE /v1/backups/{id}":
			default:
				if !upload {
					next.ServeHTTP(w, r)
					return
				}
			}
			principal := auth.MustPrincipal(r.Context())
			if upload && requireVerified && !principal.EmailVerified {
				httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeEmailUnverified, "verify your email address before writing cloud data")
				return
			}
			userID := principal.UserID
			mu.Lock()
			count := inflight[userID]
			if count < 0 || (exclusive && count != 0) {
				mu.Unlock()
				httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "another cloud operation is in progress")
				return
			}
			if exclusive {
				inflight[userID] = -1
			} else {
				inflight[userID]++
			}
			mu.Unlock()
			defer func() {
				mu.Lock()
				defer mu.Unlock()
				if exclusive || inflight[userID] == 1 {
					delete(inflight, userID)
				} else {
					inflight[userID]--
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
