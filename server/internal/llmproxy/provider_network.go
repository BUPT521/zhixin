package llmproxy

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"time"
)

var errProviderAddress = errors.New("model source must use a public HTTPS address")

func (p *Proxy) sendToProvider(req *http.Request, provider *liveProvider) (*http.Response, error) {
	if p.publicClient == nil {
		return p.client.Do(req)
	}
	if req.URL.Scheme != "https" {
		return nil, errProviderAddress
	}
	return p.publicClient.Do(req)
}

// Resolve once and dial a checked IP directly. The HTTP transport still uses
// the original hostname for TLS certificate verification and the Host header.
func dialPublicProvider(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, errProviderAddress
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil, err
	}
	dialer := net.Dialer{KeepAlive: 30 * time.Second}
	lastErr := errProviderAddress
	for _, addr := range addresses {
		if !publicProviderIP(addr) {
			continue
		}
		conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(addr.String(), port))
		if err == nil {
			return conn, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

var nonPublicV4 = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

var globalV6 = netip.MustParsePrefix("2000::/3")
var tunneledV6 = netip.MustParsePrefix("2002::/16")

func publicProviderIP(addr netip.Addr) bool {
	addr = addr.Unmap()
	if !addr.IsGlobalUnicast() || addr.IsPrivate() {
		return false
	}
	if addr.Is6() {
		return globalV6.Contains(addr) && !tunneledV6.Contains(addr)
	}
	for _, block := range nonPublicV4 {
		if block.Contains(addr) {
			return false
		}
	}
	return true
}
