package auth

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

type ctxKey int

const principalKey ctxKey = iota

// PrincipalFrom returns the caller set by Require. Handlers mounted behind
// Require can rely on ok being true.
func PrincipalFrom(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey).(Principal)
	return p, ok
}

// WithPrincipal is exposed for tests of handlers in other packages.
func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey, p)
}

// Require rejects requests without a valid "Authorization: Bearer" access token.
func (s *Service) Require(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin"`)
			httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "missing bearer token")
			return
		}
		p, err := s.Authenticate(r.Context(), token)
		if errors.Is(err, ErrInvalidToken) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin", error="invalid_token"`)
			httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "access token is invalid or expired")
			return
		}
		if err != nil {
			httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
			return
		}
		next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
	})
}

// Handler exposes the /v1/auth and /v1/me routes.
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
	// byAddr 限制同一来源地址的注册与登录尝试，两个入口共用一个桶，换入口不能
	// 多得额度；刷新令牌同时按账号与来源地址限制（ADR-0015 第 5 条）。为零值时
	// 一律放行。
	byAddr    *ratelimit.Limiter
	byAccount *ratelimit.Limiter
}

func NewHandler(svc *Service, log *slog.Logger, maxBytes int64, byAddr, byAccount *ratelimit.Limiter) *Handler {
	if byAddr == nil {
		byAddr = ratelimit.Disabled()
	}
	if byAccount == nil {
		byAccount = ratelimit.Disabled()
	}
	return &Handler{svc: svc, log: log, maxBytes: maxBytes, byAddr: byAddr, byAccount: byAccount}
}

// remoteKey 取来源地址；取不到时归到同一个键，宁可影响本机也不放行。
func remoteKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		return r.RemoteAddr
	}
	return host
}

// tooMany 写 429 并带上 Retry-After；客户端据此退避，不解析 detail。
func tooMany(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Retry-After", "1")
	httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "too many attempts, retry later")
}

// Register mounts the routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/register", h.register)
	mux.HandleFunc("POST /v1/auth/login", h.login)
	mux.HandleFunc("POST /v1/auth/refresh", h.refresh)
	mux.Handle("POST /v1/auth/logout", h.svc.Require(http.HandlerFunc(h.logout)))
	mux.Handle("GET /v1/me", h.svc.Require(http.HandlerFunc(h.me)))
	mux.Handle("DELETE /v1/me", h.svc.Require(http.HandlerFunc(h.deleteMe)))
}

type credentials struct {
	Email      string `json:"email"`
	Password   string `json:"password"`
	DeviceName string `json:"device_name"`
}

func (h *Handler) register(w http.ResponseWriter, r *http.Request) {
	if !h.byAddr.Allow("auth:" + remoteKey(r)) {
		tooMany(w, r)
		return
	}
	var in credentials
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	t, err := h.svc.Register(r.Context(), in.Email, in.Password, in.DeviceName)
	switch {
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "email must be a plain address and password 8 to 128 characters")
	case errors.Is(err, ErrEmailTaken):
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeEmailTaken, "")
	case err != nil:
		h.internal(w, r, err)
	default:
		httpx.WriteJSON(w, http.StatusCreated, t)
	}
}

func (h *Handler) login(w http.ResponseWriter, r *http.Request) {
	if !h.byAddr.Allow("auth:" + remoteKey(r)) {
		tooMany(w, r)
		return
	}
	var in credentials
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	t, err := h.svc.Login(r.Context(), in.Email, in.Password, in.DeviceName)
	switch {
	case errors.Is(err, ErrInvalidCredentials):
		httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeInvalidCredentials, "")
	case err != nil:
		h.internal(w, r, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, t)
	}
}

func (h *Handler) refresh(w http.ResponseWriter, r *http.Request) {
	var in struct {
		RefreshToken string `json:"refresh_token"`
	}
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	// 刷新令牌按账号与来源地址同时限流：分布在多个地址上的尝试按地址限不住，
	// 同一地址换账号的尝试按账号限不住。
	if !h.byAccount.Allow("refresh:"+in.RefreshToken, "refresh-ip:"+remoteKey(r)) {
		tooMany(w, r)
		return
	}
	t, err := h.svc.Refresh(r.Context(), in.RefreshToken)
	switch {
	case errors.Is(err, ErrInvalidToken):
		httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "refresh token is invalid, expired or already used")
	case err != nil:
		h.internal(w, r, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, t)
	}
}

func (h *Handler) logout(w http.ResponseWriter, r *http.Request) {
	p, _ := PrincipalFrom(r.Context())
	if err := h.svc.Logout(r.Context(), p); err != nil {
		h.internal(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type meResponse struct {
	UserID    string    `json:"user_id"`
	Email     string    `json:"email"`
	CreatedAt time.Time `json:"created_at"`
}

func (h *Handler) me(w http.ResponseWriter, r *http.Request) {
	p, _ := PrincipalFrom(r.Context())
	u, err := h.svc.User(r.Context(), p)
	if err != nil {
		h.internal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, meResponse{UserID: u.ID, Email: u.Email, CreatedAt: u.CreatedAt})
}

func (h *Handler) deleteMe(w http.ResponseWriter, r *http.Request) {
	p, _ := PrincipalFrom(r.Context())
	if err := h.svc.DeleteAccount(r.Context(), p); err != nil {
		h.internal(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) internal(w http.ResponseWriter, r *http.Request, err error) {
	h.log.Error("auth handler failed", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
}
