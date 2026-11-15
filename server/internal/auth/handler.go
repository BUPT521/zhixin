package auth

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strconv"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

type ctxKey int

const principalKey ctxKey = iota

// PrincipalFrom returns the caller set by Middleware, or false when the handler
// runs on a public route.
func PrincipalFrom(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey).(Principal)
	return p, ok
}

// MustPrincipal returns the caller set by Middleware. It panics when a protected
// handler runs without the middleware in front of it: that is a wiring defect,
// and httpx.Recover turns it into a 500 rather than serving another account.
func MustPrincipal(ctx context.Context) Principal {
	p, ok := PrincipalFrom(ctx)
	if !ok {
		panic("auth: protected handler ran without the authentication middleware")
	}
	return p
}

// withPrincipal stores the caller for PrincipalFrom.
func withPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey, p)
}

// Handler exposes the /v1/auth and /v1/me routes.
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
	// byAddr 限制同一来源地址的注册与登录尝试，两个入口共用一个桶，换入口不能
	// 多得额度；刷新令牌同时按账号与来源地址限制（ADR-0015 第 5 条）。为零值时
	// 一律放行。
	byAddr        *ratelimit.Limiter
	refreshLimits *ratelimit.Limiter
}

func NewHandler(svc *Service, log *slog.Logger, maxBytes int64, byAddr, refreshLimits *ratelimit.Limiter) *Handler {
	if byAddr == nil {
		byAddr = ratelimit.Disabled()
	}
	if refreshLimits == nil {
		refreshLimits = ratelimit.Disabled()
	}
	return &Handler{svc: svc, log: log, maxBytes: maxBytes, byAddr: byAddr, refreshLimits: refreshLimits}
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
func tooMany(w http.ResponseWriter, r *http.Request, retryAfter int64) {
	w.Header().Set("Retry-After", strconv.FormatInt(retryAfter, 10))
	httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "too many attempts, retry later")
}

// tokensJSON 把服务层的令牌结果转成契约类型，响应字段只在这里出现一次。
func tokensJSON(t Tokens) api.Tokens {
	tokenType := api.TokensTokenType(t.TokenType)
	return api.Tokens{
		AccessToken:      &t.AccessToken,
		RefreshToken:     &t.RefreshToken,
		TokenType:        &tokenType,
		AccessExpiresAt:  &t.AccessExpiresAt,
		RefreshExpiresAt: &t.RefreshExpiresAt,
		UserId:           &t.UserID,
	}
}

// optional 把契约里的可选字符串取成服务层使用的空串。
func optional(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func (h *Handler) Register(w http.ResponseWriter, r *http.Request) {
	if delay := h.byAddr.Take(remoteKey(r)); delay > 0 {
		tooMany(w, r, delay)
		return
	}
	var in api.Credentials
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	t, err := h.svc.Register(r.Context(), string(in.Email), in.Password, optional(in.DeviceName))
	switch {
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "email must be a plain address and password 8 to 128 characters")
	case errors.Is(err, ErrEmailTaken):
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeEmailTaken, "")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusCreated, tokensJSON(t))
	}
}

func (h *Handler) Login(w http.ResponseWriter, r *http.Request) {
	if delay := h.byAddr.Take(remoteKey(r)); delay > 0 {
		tooMany(w, r, delay)
		return
	}
	var in api.Credentials
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	t, err := h.svc.Login(r.Context(), string(in.Email), in.Password, optional(in.DeviceName))
	switch {
	case errors.Is(err, ErrInvalidCredentials):
		httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeInvalidCredentials, "")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, tokensJSON(t))
	}
}

func (h *Handler) Refresh(w http.ResponseWriter, r *http.Request) {
	if delay := h.refreshLimits.Take("address:" + remoteKey(r)); delay > 0 {
		tooMany(w, r, delay)
		return
	}
	var in api.PostV1AuthRefreshJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	var accountDelay int64
	t, err := h.svc.refresh(r.Context(), in.RefreshToken, func(userID string) bool {
		accountDelay = h.refreshLimits.Take("account:" + userID)
		return accountDelay == 0
	})
	switch {
	case errors.Is(err, errRefreshLimited):
		tooMany(w, r, accountDelay)
	case errors.Is(err, ErrInvalidToken):
		httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "refresh token is invalid, expired or already used")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, tokensJSON(t))
	}
}

func (h *Handler) Logout(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	if err := h.svc.Logout(r.Context(), p); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	u, err := h.svc.User(r.Context(), p)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.Me{UserId: u.ID, Email: u.Email, CreatedAt: u.CreatedAt})
}

func (h *Handler) DeleteMe(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	if err := h.svc.DeleteAccount(r.Context(), p); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
