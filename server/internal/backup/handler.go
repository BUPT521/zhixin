package backup

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler exposes /v1/backups.
type Handler struct {
	store         Store
	log           *slog.Logger
	maxBytes      int64
	keep          int
	schemaVersion int
	now           func() time.Time
}

func NewHandler(store Store, log *slog.Logger, maxBytes int64, keep, schemaVersion int) *Handler {
	return &Handler{store: store, log: log, maxBytes: maxBytes, keep: keep, schemaVersion: schemaVersion, now: time.Now}
}

func (h *Handler) Register(mux *http.ServeMux, require func(http.Handler) http.Handler) {
	mux.Handle("POST /v1/backups", require(http.HandlerFunc(h.upload)))
	mux.Handle("GET /v1/backups", require(http.HandlerFunc(h.list)))
	mux.Handle("GET /v1/backups/{id}", require(http.HandlerFunc(h.download)))
	mux.Handle("DELETE /v1/backups/{id}", require(http.HandlerFunc(h.remove)))
}

var hexSHA256 = regexp.MustCompile(`^[0-9a-f]{64}$`)

// upload takes the raw zip as the body. Headers carry what the server checks:
// X-Content-SHA256 (hex), X-Schema-Version and an optional X-Device-Name.
func (h *Handler) upload(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	want := strings.ToLower(r.Header.Get("X-Content-SHA256"))
	if !hexSHA256.MatchString(want) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "X-Content-SHA256 must be 64 lowercase hex characters")
		return
	}
	schema, err := strconv.Atoi(r.Header.Get("X-Schema-Version"))
	if err != nil || schema != h.schemaVersion {
		// Same rule as the client restore entry: only the current version (ADR-0002).
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"schema version does not match the server", map[string]any{"schema_version": h.schemaVersion})
		return
	}
	if r.ContentLength > h.maxBytes {
		httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, fmt.Sprintf("backup exceeds %d bytes", h.maxBytes))
		return
	}

	// The memory store needs the bytes anyway; the object-storage store will
	// stream to a temporary key and promote it after the hash matches.
	body := http.MaxBytesReader(w, r.Body, h.maxBytes)
	hash := sha256.New()
	var buf bytes.Buffer
	n, err := io.Copy(io.MultiWriter(&buf, hash), body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, fmt.Sprintf("backup exceeds %d bytes", h.maxBytes))
			return
		}
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "could not read body")
		return
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != want {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "body does not match X-Content-SHA256")
		return
	}

	device := strings.TrimSpace(r.Header.Get("X-Device-Name"))
	if !utf8.ValidString(device) || utf8.RuneCountInString(device) > 64 {
		device = ""
	}
	meta := Meta{ID: newID(), SHA256: want, Size: n, SchemaVersion: schema, DeviceName: device, CreatedAt: h.now().UTC()}
	if err := h.store.Put(r.Context(), p.UserID, meta, &buf, h.keep); err != nil {
		h.internal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, meta)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	items, err := h.store.List(r.Context(), p.UserID)
	if err != nil {
		h.internal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"backups": items})
}

func (h *Handler) download(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	meta, rc, err := h.store.Open(r.Context(), p.UserID, r.PathValue("id"))
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		h.internal(w, r, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Length", strconv.FormatInt(meta.Size, 10))
	w.Header().Set("X-Content-SHA256", meta.SHA256)
	w.Header().Set("X-Schema-Version", strconv.Itoa(meta.SchemaVersion))
	_, _ = io.Copy(w, rc)
}

func (h *Handler) remove(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	err := h.store.Delete(r.Context(), p.UserID, r.PathValue("id"))
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		h.internal(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) internal(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("backup handler failed", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
}
