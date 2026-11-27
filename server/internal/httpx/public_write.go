package httpx

import (
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// PublicWrite 是公开写入口共用的限流与解码组件。反馈与匿名上报都不要求登录，
// 两者的写入流程相同：先按来源地址取一次名额，再取一次实例级名额，两层都放行
// 之后才按统一上限解码请求体，被限流的请求既不解析也不落库。
type PublicWrite struct {
	maxBytes int64
	// limits 按来源地址分桶，防止同一来源反复提交。为零值时一律放行。
	limits *ratelimit.Limiter
	// globalLimits 是整个实例的写入上限，与按地址的桶同时生效，防止换地址把表
	// 刷满。没有设置时不做全局限制。
	globalLimits *ratelimit.Limiter
	// clientHost 取来源地址；直接对端是反向代理时由装配处换成读
	// X-Forwarded-For 的实现，见 NewClientHost。
	clientHost func(*http.Request) string
}

// NewPublicWrite 组装公开写入口。limits 为 nil 时一律放行，clientHost 为 nil 时
// 只看直接对端；两者与各处理器之前的兜底相同。
func NewPublicWrite(maxBytes int64, limits *ratelimit.Limiter, clientHost func(*http.Request) string) *PublicWrite {
	if limits == nil {
		limits = ratelimit.Disabled()
	}
	if clientHost == nil {
		clientHost = RemoteHost
	}
	return &PublicWrite{maxBytes: maxBytes, limits: limits, clientHost: clientHost}
}

// SetGlobalLimiter 设置整个实例的写入上限。装配处按配置建一个限流器之后调用
// 一次；不调用时只按来源地址限制。传 nil 表示关闭。
func (p *PublicWrite) SetGlobalLimiter(l *ratelimit.Limiter) { p.globalLimits = l }

// Decode 取两层限流名额，再把请求体解成 dst。被限流时写 429 并带上
// Retry-After；正文不合法时按 DecodeJSON 的口径写 problem。两种情况下都返回
// false，调用方直接返回即可。
func (p *PublicWrite) Decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	if delay := p.limits.Take("address:" + p.clientHost(r)); delay > 0 {
		TooMany(w, r, delay)
		return false
	}
	if p.globalLimits != nil {
		if delay := p.globalLimits.TakeOne(); delay > 0 {
			TooMany(w, r, delay)
			return false
		}
	}
	return DecodeJSON(w, r, p.maxBytes, dst)
}
