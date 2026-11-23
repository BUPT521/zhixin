package blobs

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler 提供 /v1/blobs/{sha256} 的上传、下载与存在检查。附件按内容寻址，
// 路径里的 sha256 就是内容的哈希；handler 核对哈希与协议，大小与账号范围由
// Service 负责。
type Handler struct {
	svc *Service
	log *slog.Logger
}

// NewHandler 组装附件接口。
func NewHandler(svc *Service, log *slog.Logger) *Handler {
	return &Handler{svc: svc, log: log}
}

// Head 只回答存在与否。HEAD 不返回响应体，所以错误也只给状态码，客户端按
// 200 与 404 分支即可。
func (h *Handler) Head(w http.ResponseWriter, r *http.Request, sha string) {
	if !httpx.ValidSHA256(sha) {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	p := auth.MustPrincipal(r.Context())
	size, err := h.svc.Stat(r.Context(), p.UserID, sha)
	if errors.Is(err, ErrNotFound) {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.WriteHeader(http.StatusOK)
}

func (h *Handler) Get(w http.ResponseWriter, r *http.Request, sha string) {
	if !httpx.ValidSHA256(sha) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "sha256 must be 64 lowercase hex characters")
		return
	}
	p := auth.MustPrincipal(r.Context())
	rc, size, err := h.svc.Open(r.Context(), p.UserID, sha)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("X-Content-SHA256", sha)
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, rc)
}

func (h *Handler) Put(w http.ResponseWriter, r *http.Request, sha string) {
	if !httpx.ValidSHA256(sha) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "sha256 must be 64 lowercase hex characters")
		return
	}
	p := auth.MustPrincipal(r.Context())
	spool, ok := httpx.SpoolVerified(w, r, h.log, httpx.SpoolCheck{
		Limit:    h.svc.MaxBytes(),
		SHA256:   sha,
		TooLarge: "attachment is too large",
		Mismatch: "body does not match the sha256 in the path",
	})
	if !ok {
		return
	}
	defer spool.Close()

	data, err := spool.Reader()
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	if err := h.svc.Put(r.Context(), p.UserID, sha, spool.Size, data); err != nil {
		if errors.Is(err, ErrTooLarge) {
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, "attachment is too large")
			return
		}
		// 账号总量超限时给出已用量与上限：客户端据此提示用户先删附件，而不是
		// 反复重试同一个请求（契约的 extra 字段）。
		var full *StorageFullError
		if errors.As(err, &full) {
			httpx.WriteProblemExtra(w, r, http.StatusRequestEntityTooLarge, httpx.CodeStorageFull,
				"account attachment storage is full",
				map[string]any{"used_bytes": full.Used, "limit_bytes": full.Limit})
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}
