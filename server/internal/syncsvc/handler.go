package syncsvc

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler exposes /v1/sync. It parses HTTP and maps service errors; validation
// and page bounds live in Service. Responses are the contract's generated
// types, so a field added to api/openapi.yaml reaches the client without a
// second definition here.
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
	// gate 在写数据之前问一次“这个账号是不是正在清除云端数据”；它由装配
	// 注入，没有注入时不拦请求。
	gate func(ctx context.Context, userID string) error
}

// NewHandler wires the handler.
func NewHandler(svc *Service, log *slog.Logger, maxBytes int64) *Handler {
	return &Handler{svc: svc, log: log, maxBytes: maxBytes}
}

// SetPurgeGate 注入清除期间的写拦截。gate 返回 cloudpurge.ErrPurging 时，
// Push 与 Reset 回 409 并且不写数据；返回其它错误按 500 处理。装配时传
// cloudpurge.Service.Gate。
func (h *Handler) SetPurgeGate(gate func(ctx context.Context, userID string) error) {
	h.gate = gate
}

// allowWrite 在清除进行时写好 409 并返回 false，调用方据此直接返回。
func (h *Handler) allowWrite(w http.ResponseWriter, r *http.Request, userID string) bool {
	if h.gate == nil {
		return true
	}
	if err := h.gate(r.Context(), userID); err != nil {
		if errors.Is(err, cloudpurge.ErrPurging) {
			httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "cloud purge in progress")
			return false
		}
		httpx.WriteInternal(w, r, h.log, err)
		return false
	}
	return true
}

func (h *Handler) Head(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	head, err := h.svc.Head(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.SyncHead{Head: head, SchemaVersion: h.svc.SchemaVersion()})
}

func (h *Handler) Pull(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	p := auth.MustPrincipal(r.Context())
	result, err := h.svc.Pull(r.Context(), p.UserID, params.After, params.Limit)
	if err != nil {
		if errors.Is(err, ErrInvalid) {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "after must be non-negative and limit between 1 and 1000")
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.CommitPage{
		Commits: result.Commits,
		Head:    result.Head,
		HasMore: result.HasMore,
	})
}

func (h *Handler) Push(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if !h.allowWrite(w, r, p.UserID) {
		return
	}
	var in api.PostV1SyncCommitsJSONBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	head, err := h.svc.Push(r.Context(), p.UserID, in.BaseSeq, in.Commits)
	if errors.Is(err, ErrHeadMoved) {
		httpx.WriteProblemExtra(w, r, http.StatusConflict, httpx.CodeConflict,
			"pull and apply remote commits first", map[string]any{"head": head})
		return
	}
	if errors.Is(err, ErrInvalid) {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"commit failed validation", map[string]any{"schema_version": h.svc.SchemaVersion()})
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.PushResult{Head: head})
}

// Reset 清空当前账号的提交序列并把 head 重置为 0。空序列也回 204，客户端只按
// 状态码判断，不需要先看 head 再决定调不调用。
func (h *Handler) Reset(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if !h.allowWrite(w, r, p.UserID) {
		return
	}
	if err := h.svc.Reset(r.Context(), p.UserID); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
