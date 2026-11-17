package retention

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// Handler 提供 POST /v1/telemetry/active。公开接口：没有账号的设备也要能上报，
// 处理器不读 Authorization；限流按来源地址，防止脚本刷表。
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
	limits   *ratelimit.Limiter
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

// Report 接收一次匿名活跃。成功与“今天已经记录过”都返回 204，客户端不需要
// 区分；字段不合法返回 400，由客户端检查自己的安装标识生成逻辑。
func (h *Handler) Report(w http.ResponseWriter, r *http.Request) {
	if delay := h.limits.Take("address:" + h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.TelemetryPing
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	err := h.svc.RecordInstall(r.Context(), Ping{
		InstallID:  in.InstallId,
		AppVersion: valueOrEmpty(in.AppVersion),
		Platform:   valueOrEmpty(in.Platform),
	})
	switch {
	case errors.Is(err, ErrInvalid):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"install_id must be 16 to 128 letters, digits, '-' or '_'; app_version at most 64 and platform at most 32 characters")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// valueOrEmpty 把契约里的可选字符串取成服务层使用的空串。
func valueOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
