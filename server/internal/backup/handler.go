package backup

import (
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

	"github.com/BUPT521/zhixin/server/internal/api"
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

var hexSHA256 = regexp.MustCompile(`^[0-9a-f]{64}$`)

// backupJSON 把存储层的元数据转成契约类型，响应字段只在这里出现一次。
func backupJSON(m Meta) api.Backup {
	id, sha, device := m.ID, m.SHA256, m.DeviceName
	size, schema := m.Size, m.SchemaVersion
	created := m.CreatedAt
	return api.Backup{
		Id:            &id,
		Sha256:        &sha,
		Size:          &size,
		SchemaVersion: &schema,
		DeviceName:    &device,
		CreatedAt:     &created,
	}
}

// Upload takes the raw zip as the body. Headers carry what the server checks:
// X-Content-SHA256 (hex), X-Schema-Version and an optional X-Device-Name.
func (h *Handler) Upload(w http.ResponseWriter, r *http.Request, params api.PostV1BackupsParams) {
	p, _ := auth.PrincipalFrom(r.Context())
	want := params.XContentSHA256
	if !hexSHA256.MatchString(want) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "X-Content-SHA256 must be 64 lowercase hex characters")
		return
	}
	if params.XSchemaVersion != h.schemaVersion {
		// Same rule as the client restore entry: only the current version (ADR-0002).
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"schema version does not match the server", map[string]any{"schema_version": h.schemaVersion})
		return
	}
	if r.ContentLength > h.maxBytes {
		httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, fmt.Sprintf("backup exceeds %d bytes", h.maxBytes))
		return
	}

	// The body goes to a temporary file while its hash is computed: a 256 MB
	// snapshot must not sit in memory, and the store needs the exact size.
	spool, err := httpx.SpoolBody(w, r, h.maxBytes)
	if err != nil {
		switch {
		case errors.Is(err, httpx.ErrBodyTooLarge):
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, fmt.Sprintf("backup exceeds %d bytes", h.maxBytes))
		case errors.Is(err, httpx.ErrBodyRead):
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "could not read body")
		default:
			httpx.WriteInternal(w, r, h.log, err)
		}
		return
	}
	defer spool.Close()
	if spool.SHA256 != want {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "body does not match X-Content-SHA256")
		return
	}

	device := ""
	if params.XDeviceName != nil {
		device = strings.TrimSpace(*params.XDeviceName)
	}
	if !utf8.ValidString(device) || utf8.RuneCountInString(device) > 64 {
		device = ""
	}
	meta := Meta{ID: newID(), SHA256: want, Size: spool.Size, SchemaVersion: params.XSchemaVersion, DeviceName: device, CreatedAt: h.now().UTC()}
	body, err := spool.Reader()
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	if err := h.store.Put(r.Context(), p.UserID, meta, body, h.keep); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, backupJSON(meta))
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.PrincipalFrom(r.Context())
	items, err := h.store.List(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	out := make([]api.Backup, 0, len(items))
	for _, m := range items {
		out = append(out, backupJSON(m))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"backups": out})
}

func (h *Handler) Download(w http.ResponseWriter, r *http.Request, id string) {
	p, _ := auth.PrincipalFrom(r.Context())
	meta, rc, err := h.store.Open(r.Context(), p.UserID, id)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Length", strconv.FormatInt(meta.Size, 10))
	w.Header().Set("X-Content-SHA256", meta.SHA256)
	w.Header().Set("X-Schema-Version", strconv.Itoa(meta.SchemaVersion))
	_, _ = io.Copy(w, rc)
}

func (h *Handler) Delete(w http.ResponseWriter, r *http.Request, id string) {
	p, _ := auth.PrincipalFrom(r.Context())
	err := h.store.Delete(r.Context(), p.UserID, id)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
