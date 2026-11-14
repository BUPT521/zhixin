package syncsvc

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

const (
	maxPushCommits = 200
	defaultPull    = 200
	maxPull        = 1000
)

// Handler exposes /v1/sync and /v1/blobs.
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

// Register mounts the routes; require wraps each with authentication.
func (h *Handler) Register(mux *http.ServeMux, require func(http.Handler) http.Handler) {
	mux.Handle("GET /v1/sync/head", require(http.HandlerFunc(h.head)))
	mux.Handle("GET /v1/sync/commits", require(http.HandlerFunc(h.pull)))
	mux.Handle("POST /v1/sync/commits", require(http.HandlerFunc(h.push)))
	// Attachment objects addressed by SHA-256. In the contract, not built yet.
	mux.Handle("HEAD /v1/blobs/{sha256}", require(http.HandlerFunc(httpx.NotImplemented)))
	mux.Handle("GET /v1/blobs/{sha256}", require(http.HandlerFunc(httpx.NotImplemented)))
	mux.Handle("PUT /v1/blobs/{sha256}", require(http.HandlerFunc(httpx.NotImplemented)))
}

type headResponse struct {
	Head          int64 `json:"head"`
	SchemaVersion int   `json:"schema_version"`
}

func (h *Handler) head(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	head, err := h.store.Head(r.Context(), p.UserID)
	if err != nil {
		h.internal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, headResponse{Head: head, SchemaVersion: h.schemaVersion})
}

type pullResponse struct {
	Commits []Commit `json:"commits"`
	Head    int64    `json:"head"`
	HasMore bool     `json:"has_more"`
}

func (h *Handler) pull(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	q := r.URL.Query()
	after, err := strconv.ParseInt(q.Get("after"), 10, 64)
	if q.Get("after") == "" {
		after, err = 0, nil
	}
	if err != nil || after < 0 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "after must be a non-negative integer")
		return
	}
	limit := defaultPull
	if s := q.Get("limit"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 || n > maxPull {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "limit must be between 1 and 1000")
			return
		}
		limit = n
	}
	head, err := h.store.Head(r.Context(), p.UserID)
	if err != nil {
		h.internal(w, r, err)
		return
	}
	commits, err := h.store.After(r.Context(), p.UserID, after, limit)
	if err != nil {
		h.internal(w, r, err)
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

type pushRequest struct {
	BaseSeq int64    `json:"base_seq"`
	Commits []Commit `json:"commits"`
}

type pushResponse struct {
	Head int64 `json:"head"`
}

func (h *Handler) push(w http.ResponseWriter, r *http.Request) {
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
		h.internal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, pushResponse{Head: head})
}

func (h *Handler) internal(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("sync handler failed", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
}
