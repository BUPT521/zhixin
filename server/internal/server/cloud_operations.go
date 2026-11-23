package server

import (
	"net/http"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
)

// cloudWriteOperations are writes to an account's cloud data that are not in the
// upload list (they do not consume the upload rate limit or require a verified
// contact). They still take part in the in-process exclusion so that a bulk
// deletion waits for them and they answer 409 while it runs (review 9.3 V10).
var cloudWriteOperations = []string{
	"PUT /v1/sync/snapshot",
	"PUT /v1/sync/refs",
	"PUT /v1/sync/devices",
}

// cloudOperations lets writes for an account coexist and gives bulk deletion
// exclusive access for the full request, including object storage operations.
func cloudOperations(requireVerified bool) api.MiddlewareFunc {
	var mu sync.Mutex
	inflight := map[string]int{} // Positive for writes, -1 for exclusive deletion.
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			upload := routepolicy.IsUpload(r.Pattern)
			write := upload || isCloudWrite(r.Pattern)
			var exclusive bool
			switch r.Pattern {
			case "DELETE /v1/cloud", "DELETE /v1/sync/commits", "DELETE /v1/backups", "DELETE /v1/me":
				exclusive = true
			case "DELETE /v1/backups/{id}":
			default:
				if !write {
					next.ServeHTTP(w, r)
					return
				}
			}
			principal := auth.MustPrincipal(r.Context())
			if upload && requireVerified && !principal.ContactVerified {
				httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeContactUnverified, "verify one of your sign-in identities before writing cloud data")
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

// isCloudWrite reports whether a matched route is one of the non-upload writes
// that must not run while a bulk deletion is in flight.
func isCloudWrite(pattern string) bool {
	for _, item := range cloudWriteOperations {
		if item == pattern {
			return true
		}
	}
	return false
}
