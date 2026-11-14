// Package auth 的 HTTP 入口。
//
// 路由由内部/api 下的生成代码提供，这里只把契约里的路径接到既有处理器上；
// 请求解码、problem+json 与状态码仍在各处理器内部（ADR-0015 第 4 条）。
package auth

import "net/http"

// RegisterHTTP 处理 POST /v1/auth/register。
func (h *Handler) RegisterHTTP(w http.ResponseWriter, r *http.Request) { h.register(w, r) }

// LoginHTTP 处理 POST /v1/auth/login。
func (h *Handler) LoginHTTP(w http.ResponseWriter, r *http.Request) { h.login(w, r) }

// RefreshHTTP 处理 POST /v1/auth/refresh。
func (h *Handler) RefreshHTTP(w http.ResponseWriter, r *http.Request) { h.refresh(w, r) }

// LogoutHTTP 处理 POST /v1/auth/logout。
func (h *Handler) LogoutHTTP(w http.ResponseWriter, r *http.Request) { h.logout(w, r) }

// MeHTTP 处理 GET /v1/me。
func (h *Handler) MeHTTP(w http.ResponseWriter, r *http.Request) { h.me(w, r) }

// DeleteMeHTTP 处理 DELETE /v1/me。
func (h *Handler) DeleteMeHTTP(w http.ResponseWriter, r *http.Request) { h.deleteMe(w, r) }
