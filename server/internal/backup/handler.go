package backup

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler exposes /v1/backups. It checks the HTTP-level rules (schema version
// and the exact body size while spooling) and otherwise only translates HTTP
// into service calls; device-name cleaning and retention live in Service.
type Handler struct {
	svc *Service
	log *slog.Logger
}

func NewHandler(svc *Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
}

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
	p := auth.MustPrincipal(r.Context())
	want := params.XContentSHA256
	if !httpx.ValidSHA256(want) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "X-Content-SHA256 must be 64 lowercase hex characters")
		return
	}
	if params.XSchemaVersion != h.svc.SchemaVersion() {
		// Same rule as the client restore entry: only the current version (ADR-0002).
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"schema version does not match the server", map[string]any{"schema_version": h.svc.SchemaVersion()})
		return
	}

	// The body goes to a temporary file while its hash is computed: a 256 MB
	// snapshot must not sit in memory, and the store needs the exact size.
	tooLarge := fmt.Sprintf("backup exceeds %d bytes", h.svc.MaxBytes())
	spool, ok := httpx.SpoolVerified(w, r, h.log, httpx.SpoolCheck{
		Limit:    h.svc.MaxBytes(),
		SHA256:   want,
		TooLarge: tooLarge,
		Mismatch: "body does not match X-Content-SHA256",
	})
	if !ok {
		return
	}
	defer spool.Close()

	device := ""
	if params.XDeviceName != nil {
		device = strings.TrimSpace(*params.XDeviceName)
		// HTTP 头只接受 ASCII，客户端把带中文的设备名按 UTF-8 百分号编码再发；
		// 解码失败时按原样保存，避免因为一个展示字段拒绝整份备份。
		if decoded, err := url.PathUnescape(device); err == nil {
			device = strings.TrimSpace(decoded)
		}
	}
	body, err := spool.Reader()
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	meta, err := h.svc.Upload(
		r.Context(),
		p.UserID,
		want,
		params.XSchemaVersion,
		device,
		spool.Size,
		body,
	)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, backupJSON(meta))
}

func (h *Handler) List(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	items, err := h.svc.List(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	out := make([]api.Backup, 0, len(items))
	for _, m := range items {
		out = append(out, backupJSON(m))
	}
	httpx.WriteJSON(w, http.StatusOK, api.BackupList{Backups: out})
}

func (h *Handler) Download(w http.ResponseWriter, r *http.Request, id string) {
	p := auth.MustPrincipal(r.Context())
	meta, rc, err := h.svc.Open(r.Context(), p.UserID, id)
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
	p := auth.MustPrincipal(r.Context())
	err := h.svc.Delete(r.Context(), p.UserID, id)
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

// DeleteAll 清空当前账号的全部备份。空账号也回 204，客户端只按状态码判断，
// 不需要先列表再决定调不调用。
func (h *Handler) DeleteAll(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if err := h.svc.DeleteAll(r.Context(), p.UserID); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
