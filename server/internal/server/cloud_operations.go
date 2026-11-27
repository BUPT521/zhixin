package server

import (
	"net/http"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// cloudOperations lets writes for an account coexist and gives bulk deletion
// exclusive access for the full request, including object storage operations.
//
// 会写设备名册的读接口也算在内：它们持有与写请求相同的计数，清除因此不能与
// 一次名册写入交错；清除已经进行时它们照常返回，只是让处理器跳过名册更新，
// 写入不会落在提交序列清空之后。
func cloudOperations(requireVerified bool) api.MiddlewareFunc {
	var mu sync.Mutex
	// 正数是并行的写与名册更新，-1 是独占的清除。
	inflight := map[string]int{}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			policy, write := routepolicy.CloudWritePolicy(r.Pattern)
			roster := routepolicy.WritesRoster(r.Pattern)
			if !write && !roster {
				next.ServeHTTP(w, r)
				return
			}
			principal := auth.MustPrincipal(r.Context())
			if policy.Upload && requireVerified && !principal.ContactVerified {
				httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeContactUnverified, "verify one of your sign-in identities before writing cloud data")
				return
			}
			userID := principal.UserID
			mu.Lock()
			count := inflight[userID]
			if count < 0 {
				mu.Unlock()
				if roster {
					// 清除正在进行：这一次读取不更新名册，结果照常返回。
					next.ServeHTTP(w, r.WithContext(syncsvc.SuppressRosterWrite(r.Context())))
					return
				}
				httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "another cloud operation is in progress")
				return
			}
			if policy.Exclusive && count != 0 {
				mu.Unlock()
				httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "another cloud operation is in progress")
				return
			}
			if policy.Exclusive {
				inflight[userID] = -1
			} else {
				inflight[userID]++
			}
			mu.Unlock()
			defer func() {
				mu.Lock()
				defer mu.Unlock()
				if policy.Exclusive || inflight[userID] == 1 {
					delete(inflight, userID)
				} else {
					inflight[userID]--
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}
