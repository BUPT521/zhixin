// Package syncsvc 的 HTTP 入口：路由由内部/api 的生成代码提供。
package syncsvc

import "net/http"

// HeadHTTP 处理 GET /v1/sync/head。
func (h *Handler) HeadHTTP(w http.ResponseWriter, r *http.Request) { h.head(w, r) }

// PullHTTP 处理 GET /v1/sync/commits。
func (h *Handler) PullHTTP(w http.ResponseWriter, r *http.Request) { h.pull(w, r) }

// PushHTTP 处理 POST /v1/sync/commits。
func (h *Handler) PushHTTP(w http.ResponseWriter, r *http.Request) { h.push(w, r) }
