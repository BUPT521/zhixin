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
	// 末项不是地址时同样退回直接对端，不能因此分出新桶。
	if got := host(newRequest("127.0.0.1:1234", "198.51.100.1, not-an-ip")); got != "127.0.0.1" {
		t.Fatalf("最后一项不是地址时应退回直接对端，得到 %q", got)
	}
}

// TestClientHostUnmapsIPv4MappedAddresses 核对 IPv4 映射到 IPv6 的地址先还原成
// IPv4：直接对端、可信网段与 X-Forwarded-For 末项三处都按还原后的地址判断。
func TestClientHostUnmapsIPv4MappedAddresses(t *testing.T) {
	untrusted := NewClientHost(nil)
	if got := untrusted(newRequest("[::ffff:203.0.113.9]:1234", "")); got != "203.0.113.9" {
		t.Fatalf("映射地址应还原成 IPv4，得到 %q", got)
	}

	trusted := NewClientHost([]netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")})
	// 对端写成映射地址时仍然命中 127.0.0.1/32，于是看头。
	if got := trusted(newRequest("[::ffff:127.0.0.1]:1234", "198.51.100.1, 203.0.113.9")); got != "203.0.113.9" {
		t.Fatalf("映射对端应命中可信网段，得到 %q", got)
	}
	// 头的末项写成映射地址时也先还原。
	if got := trusted(newRequest("127.0.0.1:1234", "198.51.100.1, ::ffff:203.0.113.9")); got != "203.0.113.9" {
		t.Fatalf("映射的末项应还原成 IPv4，得到 %q", got)
	}
}

// TestClientHostGroupsIPv6By64 核对 IPv6 按 /64 归并：同一 /64 里的不同地址
// 共用一个桶，不同 /64 分开，否则换一个接口标识就能换一个限流桶。
func TestClientHostGroupsIPv6By64(t *testing.T) {
	host := NewClientHost(nil)
	first := host(newRequest("[2001:db8:1:2:3:4:5:6]:1234", ""))
	second := host(newRequest("[2001:db8:1:2:aaaa:bbbb:cccc:dddd]:1234", ""))
	if first != second {
		t.Fatalf("同一个 /64 应归并，得到 %q 与 %q", first, second)
	}
	if first != "2001:db8:1:2::/64" {
		t.Fatalf("IPv6 的桶键应为 /64，得到 %q", first)
	}
	if other := host(newRequest("[2001:db8:1:3::1]:1234", "")); other == first {
		t.Fatalf("不同的 /64 应当分开，得到 %q", other)
	}
}

// TestClientHostIgnoresForgedForwardedFor 核对对端不可信时，客户端自己写死的
// X-Forwarded-For 换不到另一个桶：既然不信任这个头，就只按直接对端分桶。
func TestClientHostIgnoresForgedForwardedFor(t *testing.T) {
	host := NewClientHost([]netip.Prefix{netip.MustParsePrefix("192.0.2.0/24")})
	peer := "203.0.113.9:1234"
	first := host(newRequest(peer, "198.51.100.1"))
	second := host(newRequest(peer, "198.51.100.1, 198.51.100.2"))
	if first != "203.0.113.9" || second != "203.0.113.9" {
		t.Fatalf("不可信对端的伪造头不应影响分桶，得到 %q 与 %q", first, second)
	}
}
