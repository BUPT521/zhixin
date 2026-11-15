// Package blobs 的 HTTP 入口：路由由内部/api 的生成代码提供。
package blobs

import "net/http"

// HeadHTTP 处理 HEAD /v1/blobs/{sha256}。
func (h *Handler) HeadHTTP(w http.ResponseWriter, r *http.Request, sha string) { h.head(w, r, sha) }

// GetHTTP 处理 GET /v1/blobs/{sha256}。
func (h *Handler) GetHTTP(w http.ResponseWriter, r *http.Request, sha string) { h.get(w, r, sha) }

// PutHTTP 处理 PUT /v1/blobs/{sha256}。
func (h *Handler) PutHTTP(w http.ResponseWriter, r *http.Request, sha string) { h.put(w, r, sha) }
