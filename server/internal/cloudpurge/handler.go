package cloudpurge

import (
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler 提供 DELETE /v1/cloud，只做 HTTP 与错误映射，编排在 Service。
type Handler struct {
	svc *Service
	log *slog.Logger
}

// NewHandler 组装清除接口。
func NewHandler(svc *Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
}

// Purge 清除当前账号的云端数据。空账号也回 204：客户端只按状态码判断，不需要
// 先看有没有数据。并发的清除请求与清除期间的其他写请求由进程内的中间件回 409，
// 走不到处理器；任何一步失败回 500，用户重试时从头再来。
func (h *Handler) Purge(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if err := h.svc.Purge(r.Context(), p.UserID); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
