package syncsvc

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler exposes /v1/sync. It parses HTTP and maps service errors; validation
// and page bounds live in Service.
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
}

// NewHandler wires the handler.
func NewHandler(svc *Service, log *slog.Logger, maxBytes int64) *Handler {
	return &Handler{svc: svc, log: log, maxBytes: maxBytes}
}

type headResponse struct {
	Head          int64 `json:"head"`
	SchemaVersion int   `json:"schema_version"`
}

func (h *Handler) Head(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	head, err := h.svc.Head(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, headResponse{Head: head, SchemaVersion: h.svc.SchemaVersion()})
}

type pullResponse struct {
	Commits []Commit `json:"commits"`
	Head    int64    `json:"head"`
	HasMore bool     `json:"has_more"`
}

func (h *Handler) Pull(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	p, _ := auth.PrincipalFrom(r.Context())
	result, err := h.svc.Pull(r.Context(), p.UserID, params.After, params.Limit)
	if err != nil {
		if errors.Is(err, ErrInvalid) {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "after must be non-negative and limit between 1 and 1000")
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, pullResponse{
		Commits: result.Commits,
		Head:    result.Head,
		HasMore: result.HasMore,
	})
}

// pushRequest 保留 Change 的原始 JSON。服务端不解释学习内容，也不经过
// 契约模型里的 interface{}，否则大整数会被解码成 float64 而改变数值。
type pushRequest struct {
	BaseSeq int64    `json:"base_seq"`
	Commits []Commit `json:"commits"`
}

type pushResponse struct {
	Head int64 `json:"head"`
}

func (h *Handler) Push(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	var in pushRequest
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
	httpx.WriteJSON(w, http.StatusOK, pushResponse{Head: head})
}
