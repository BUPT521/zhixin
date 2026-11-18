package httpx

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func newRequest(remoteAddr, forwardedFor string) *http.Request {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = remoteAddr
	if forwardedFor != "" {
		req.Header.Set("X-Forwarded-For", forwardedFor)
	}
	return req
}

func TestRemoteHost(t *testing.T) {
	if got := RemoteHost(newRequest("203.0.113.9:1234", "")); got != "203.0.113.9" {
		t.Fatalf("RemoteHost = %q", got)
	}
	// 取不出主机名时退回原值，让这些请求归到同一个键。
	if got := RemoteHost(newRequest("not-an-address", "")); got != "not-an-address" {
		t.Fatalf("RemoteHost = %q", got)
	}
}

func TestClientHostIgnoresForwardedForByDefault(t *testing.T) {
	// 对外直接暴露时头由客户端自己写，不能拿来分桶。
	host := NewClientHost(nil)
	got := host(newRequest("203.0.113.9:1234", "198.51.100.1"))
	if got != "203.0.113.9" {
		t.Fatalf("默认应只看直接对端，得到 %q", got)
	}
}

func TestClientHostUsesLastForwardedForBehindProxy(t *testing.T) {
	// 前面的项可以由客户端伪造，最后一项由 nginx 追加。
	host := NewClientHost([]netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")})
	got := host(newRequest("127.0.0.1:1234", "198.51.100.1, 203.0.113.9"))
	if got != "203.0.113.9" {
		t.Fatalf("应取 X-Forwarded-For 的最后一项，得到 %q", got)
	}
}

func TestClientHostFallsBackWithoutForwardedFor(t *testing.T) {
	host := NewClientHost([]netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")})
	if got := host(newRequest("127.0.0.1:1234", "")); got != "127.0.0.1" {
		t.Fatalf("没有头时应退回直接对端，得到 %q", got)
	}
	if got := host(newRequest("127.0.0.1:1234", "198.51.100.1, ")); got != "127.0.0.1" {
		t.Fatalf("最后一项为空时应退回直接对端，得到 %q", got)
	}
}
