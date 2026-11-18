package feedback

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// Handler 提供 POST /v1/feedback。字段校验在 Service，这里只做限流、解码与
// 错误映射；反馈正文与诊断摘要不写日志，与访问日志同一口径。
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
	// limits 按来源地址限制提交频率，防止有人反复填表。为零值时一律放行。
	limits *ratelimit.Limiter
	// globalLimits 是整个实例的反馈写入上限，键固定为 "global"，与按地址的桶
	// 同时生效，防止换地址把整张表刷满。没有设置时不做全局限制。
	globalLimits *ratelimit.Limiter
	// clientHost 取来源地址；直接对端是反向代理时由装配处换成读
	// X-Forwarded-For 的实现，见 httpx.NewClientHost。
	clientHost func(*http.Request) string
}

func NewHandler(
	svc *Service,
	log *slog.Logger,
	maxBytes int64,
	limits *ratelimit.Limiter,
	clientHost func(*http.Request) string,
) *Handler {
	if limits == nil {
		limits = ratelimit.Disabled()
	}
	if clientHost == nil {
		clientHost = httpx.RemoteHost
	}
	return &Handler{svc: svc, log: log, maxBytes: maxBytes, limits: limits, clientHost: clientHost}
}

// SetGlobalLimiter 设置整个实例的反馈写入上限。装配处按配置建一个限流器之后
// 调用一次；不调用时只按来源地址限制，与之前的行为一致。传 nil 表示关闭。
func (h *Handler) SetGlobalLimiter(l *ratelimit.Limiter) { h.globalLimits = l }

// globalLimiterKey 是全局桶的键。全局桶只有一个键，与按地址的桶互不共用，
// 两者可以各用一个 Limiter。
const globalLimiterKey = "global"

// Submit 接收一条反馈。登录与否都能提交，处理器不读 Authorization，也不把
// 反馈绑定到账号。
func (h *Handler) Submit(w http.ResponseWriter, r *http.Request) {
	if h.globalLimits != nil {
		if delay := h.globalLimits.Take(globalLimiterKey); delay > 0 {
			httpx.TooMany(w, r, delay)
			return
		}
	}
	if delay := h.limits.Take("address:" + h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.Feedback
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	sub := Submission{
		Content:     in.Content,
		AppVersion:  valueOrEmpty(in.AppVersion),
		Platform:    valueOrEmpty(in.Platform),
		Diagnostics: valueOrEmpty(in.Diagnostics),
	}
	if in.Contact != nil {
		sub.Contact = string(*in.Contact)
	}
	receipt, err := h.svc.Submit(r.Context(), sub)
	switch {
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"content must be 1 to 4000 characters, contact must be a plain email, app_version at most 64, platform at most 32 and diagnostics at most 65536 characters")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusCreated, api.FeedbackReceipt{
			Id:        receipt.ID,
			CreatedAt: receipt.CreatedAt,
		})
	}
}

// valueOrEmpty 把契约里的可选字符串取成服务层使用的空串。
func valueOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
