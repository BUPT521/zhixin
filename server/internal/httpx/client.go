package httpx

import (
	"net"
	"net/http"
	"net/netip"
	"slices"
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
// 只有直接对端落在 trusted 里时才相信 X-Forwarded-For 的末项：末项是直连的
// 反向代理写入的，前面的项由客户端自己写，不可信。对端不可信、头的末项不是
// 合法地址或列表为空时都回退到直接对端，客户端因此换不到另一个限流桶。
// IPv6 按 /64 分桶，其余按地址分桶；IPv4 映射到 IPv6 的地址先还原成 IPv4。
func NewClientHost(trusted []netip.Prefix) func(*http.Request) string {
	return func(r *http.Request) string {
		peer := peerAddr(r)
		if !peer.IsValid() || !trustedPeer(peer, trusted) {
			return bucketKey(peer, RemoteHost(r))
		}
		value := r.Header.Get("X-Forwarded-For")
		if value == "" {
			return bucketKey(peer, RemoteHost(r))
		}
		parts := strings.Split(value, ",")
		last := strings.TrimSpace(parts[len(parts)-1])
		addr, err := netip.ParseAddr(last)
		if err != nil || !addr.IsValid() {
			return bucketKey(peer, RemoteHost(r))
		}
		return bucketKey(addr.Unmap(), last)
	}
}

// peerAddr 解析直接对端；解析不了时返回无效地址。
func peerAddr(r *http.Request) netip.Addr {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		return netip.Addr{}
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}
	}
	return addr.Unmap()
}

// trustedPeer 报告对端是否命中配置的反向代理地址或网段。
func trustedPeer(peer netip.Addr, trusted []netip.Prefix) bool {
	return slices.ContainsFunc(trusted, func(p netip.Prefix) bool { return p.Contains(peer) })
}

// bucketKey 把地址变成限流桶的键：IPv6 归并到 /64，其余按地址原文。地址无效
// 时退回传入的原文，让这些请求互相影响而不是各自获得新桶。
func bucketKey(addr netip.Addr, raw string) string {
	if !addr.IsValid() {
		return "raw:" + raw
	}
	if addr.Is6() && !addr.Is4In6() {
		return netip.PrefixFrom(addr, 64).Masked().String()
	}
	return addr.String()
}
