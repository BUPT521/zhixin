package cloudpurge

import (
	"errors"
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
// 先看有没有数据。清除已经进行中（或标记还新）时回 409，客户端退避后重试；
// 任何一步失败回 500，标记保留，下一次请求从头再来。
func (h *Handler) Purge(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	err := h.svc.Purge(r.Context(), p.UserID)
	if errors.Is(err, ErrInProgress) || errors.Is(err, ErrPurging) {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "cloud purge in progress")
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
