package httpx

import (
	"net"
	"net/http"
	"strings"
)

// RemoteHost 取直接对端的地址，按地址限流与按地址分桶的接口共用这一处。
// 取不到时返回原值，这些请求归到同一个键，宁可互相影响也不放行。
func RemoteHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		return r.RemoteAddr
	}
	return host
}

// NewClientHost 返回取来源地址的函数，供按地址限流的处理器使用。
//
// trustProxy 为真时按 X-Forwarded-For 的最后一项取地址：第一套实例只监听回环
// 地址，前面是项目组的 nginx，nginx 会把真实来源追加在末尾，前面的项由客户端
// 自己写，不可信。对外直接暴露时不能打开这个开关，否则客户端自己写这个头就能
// 换一个桶、绕过按地址限流。
func NewClientHost(trustProxy bool) func(*http.Request) string {
	if !trustProxy {
		return RemoteHost
	}
	return func(r *http.Request) string {
		value := r.Header.Get("X-Forwarded-For")
		if value == "" {
			return RemoteHost(r)
		}
		parts := strings.Split(value, ",")
		last := strings.TrimSpace(parts[len(parts)-1])
		if last == "" {
			return RemoteHost(r)
		}
		return last
	}
}
