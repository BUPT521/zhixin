// Package backup 的 HTTP 入口：路由由内部/api 的生成代码提供。
package backup

import "net/http"

// UploadHTTP 处理 POST /v1/backups。
func (h *Handler) UploadHTTP(w http.ResponseWriter, r *http.Request) { h.upload(w, r) }

// ListHTTP 处理 GET /v1/backups。
func (h *Handler) ListHTTP(w http.ResponseWriter, r *http.Request) { h.list(w, r) }

// DownloadHTTP 处理 GET /v1/backups/{id}。
func (h *Handler) DownloadHTTP(w http.ResponseWriter, r *http.Request) {
	h.download(w, r)
}

// DeleteHTTP 处理 DELETE /v1/backups/{id}。
func (h *Handler) DeleteHTTP(w http.ResponseWriter, r *http.Request) { h.remove(w, r) }
