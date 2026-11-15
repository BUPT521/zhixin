package syncsvc

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

const (
	maxPushCommits = 200
	defaultPull    = 200
	maxPull        = 1000
)

// Handler exposes /v1/sync.
type Handler struct {
	store         Store
	log           *slog.Logger
	maxBytes      int64
	schemaVersion int
}

// NewHandler wires the handler. schemaVersion is the client data schema the
// server accepts; commits from any other version are rejected (ADR-0002).
func NewHandler(store Store, log *slog.Logger, maxBytes int64, schemaVersion int) *Handler {
	return &Handler{store: store, log: log, maxBytes: maxBytes, schemaVersion: schemaVersion}
}

type headResponse struct {
	Head          int64 `json:"head"`
	SchemaVersion int   `json:"schema_version"`
}

func (h *Handler) Head(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	head, err := h.store.Head(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, headResponse{Head: head, SchemaVersion: h.schemaVersion})
}

type pullResponse struct {
	Commits []Commit `json:"commits"`
	Head    int64    `json:"head"`
	HasMore bool     `json:"has_more"`
}

func (h *Handler) Pull(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	p, _ := auth.PrincipalFrom(r.Context())
	after := int64(0)
	if params.After != nil {
		after = *params.After
	}
	if after < 0 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "after must be a non-negative integer")
		return
	}
	limit := defaultPull
	if params.Limit != nil {
		if *params.Limit < 1 || *params.Limit > maxPull {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "limit must be between 1 and 1000")
			return
		}
		limit = *params.Limit
	}
	head, err := h.store.Head(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	commits, err := h.store.After(r.Context(), p.UserID, after, limit)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	if commits == nil {
		commits = []Commit{}
	}
	last := after
	if n := len(commits); n > 0 {
		last = commits[n-1].Seq
	}
	httpx.WriteJSON(w, http.StatusOK, pullResponse{Commits: commits, Head: head, HasMore: last < head})
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
	if len(in.Commits) == 0 || len(in.Commits) > maxPushCommits {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "push 1 to 200 commits at a time")
		return
	}
	for i := range in.Commits {
		in.Commits[i].Seq = 0
		if err := Validate(in.Commits[i], h.schemaVersion); err != nil {
			httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
				"commit failed validation", map[string]any{"index": i, "schema_version": h.schemaVersion})
			return
		}
	}
	head, err := h.store.Append(r.Context(), p.UserID, in.BaseSeq, in.Commits)
	if errors.Is(err, ErrHeadMoved) {
		httpx.WriteProblemExtra(w, r, http.StatusConflict, httpx.CodeConflict,
			"pull and apply remote commits first", map[string]any{"head": head})
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, pushResponse{Head: head})
}
