package blobs

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler 提供 /v1/blobs/{sha256} 的上传、下载与存在检查。附件按内容寻址，
// 路径里的 sha256 就是内容的哈希；服务端在写入之前核对一遍，不符的请求不落库。
type Handler struct {
	store    Store
	log      *slog.Logger
	maxBytes int64
}

// NewHandler 组装附件接口；maxBytes 是单个附件的上限。
func NewHandler(store Store, log *slog.Logger, maxBytes int64) *Handler {
	return &Handler{store: store, log: log, maxBytes: maxBytes}
}

var shaPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// head 只回答存在与否。HEAD 不返回响应体，所以错误也只给状态码，客户端按
// 200 与 404 分支即可。
func (h *Handler) head(w http.ResponseWriter, r *http.Request, sha string) {
	if !shaPattern.MatchString(sha) {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	p, _ := auth.PrincipalFrom(r.Context())
	size, err := h.store.Stat(r.Context(), p.UserID, sha)
	if errors.Is(err, ErrNotFound) {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if err != nil {
		h.internal(w, r, err)
		return
	}
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.WriteHeader(http.StatusOK)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request, sha string) {
	if !shaPattern.MatchString(sha) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "sha256 must be 64 lowercase hex characters")
		return
	}
	p, _ := auth.PrincipalFrom(r.Context())
	rc, size, err := h.store.Open(r.Context(), p.UserID, sha)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		h.internal(w, r, err)
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("X-Content-SHA256", sha)
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, rc)
}

func (h *Handler) put(w http.ResponseWriter, r *http.Request, sha string) {
	if !shaPattern.MatchString(sha) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "sha256 must be 64 lowercase hex characters")
		return
	}
	if r.ContentLength > h.maxBytes {
		httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, "attachment is too large")
		return
	}
	spool, err := httpx.SpoolBody(w, r, h.maxBytes)
	if err != nil {
		switch {
		case errors.Is(err, httpx.ErrBodyTooLarge):
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, "attachment is too large")
		case errors.Is(err, httpx.ErrBodyRead):
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "could not read body")
		default:
			h.internal(w, r, err)
		}
		return
	}
	defer spool.Close()
	if spool.SHA256 != sha {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "body does not match the sha256 in the path")
		return
	}
	p, _ := auth.PrincipalFrom(r.Context())
	data, err := spool.Reader()
	if err != nil {
		h.internal(w, r, err)
		return
	}
	if err := h.store.Save(r.Context(), p.UserID, sha, spool.Size, data); err != nil {
		h.internal(w, r, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (h *Handler) internal(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("blob handler failed", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
}
