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
	svc   *Service
	log   *slog.Logger
	write *httpx.PublicWrite
}

func NewHandler(
	svc *Service,
	log *slog.Logger,
	maxBytes int64,
	limits *ratelimit.Limiter,
	clientHost func(*http.Request) string,
) *Handler {
	return &Handler{
		svc:   svc,
		log:   log,
		write: httpx.NewPublicWrite(maxBytes, limits, clientHost),
	}
}

// SetGlobalLimiter 设置整个实例的匿名上报写入上限。装配处按配置建一个限流器
// 之后调用一次；不调用时只按来源地址限制，与之前的行为一致。传 nil 表示关闭。
func (h *Handler) SetGlobalLimiter(l *ratelimit.Limiter) { h.write.SetGlobalLimiter(l) }

// Report 接收一次匿名活跃。成功与“今天已经记录过”都返回 204，客户端不需要
// 区分；字段不合法返回 400，由客户端检查自己的安装标识生成逻辑。
func (h *Handler) Report(w http.ResponseWriter, r *http.Request) {
	var in api.TelemetryPing
	if !h.write.Decode(w, r, &in) {
		return
	}
	err := h.svc.RecordInstall(r.Context(), Ping{
		InstallID: in.InstallId,
	})
	switch {
	case errors.Is(err, ErrInvalid):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"install_id must be 16 to 128 letters, digits, '-' or '_'")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
