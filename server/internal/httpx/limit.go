package httpx

import (
	"net/http"
	"strconv"
)

// TooMany 写 429 并带上 Retry-After；客户端据此退避，不解析 detail。
// 按来源地址、按账号或按邮箱限流的入口共用这一处，429 的响应体与响应头因此
// 只有一种写法。
func TooMany(w http.ResponseWriter, r *http.Request, retryAfter int64) {
	if retryAfter < 1 {
		retryAfter = 1
	}
	w.Header().Set("Retry-After", strconv.FormatInt(retryAfter, 10))
	WriteProblem(w, r, http.StatusTooManyRequests, CodeRateLimited, "too many requests, retry later")
}
