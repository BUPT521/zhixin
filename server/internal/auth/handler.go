package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

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
	// codeLimits 限制发送验证码与重设密码的尝试：按账号、来源地址与邮箱各记
	// 一个桶，防止同一账号被反复发信，也防止换账号刷同一个邮箱。
	codeLimits *ratelimit.Limiter
	// clientHost 取来源地址；直接对端是反向代理时由装配处换成读
	// X-Forwarded-For 的实现，见 httpx.NewClientHost。
	clientHost func(*http.Request) string
	// loginFails 是按账号的登录失败预算：登录前非消费地检查，只有密码错误才
	// 扣一个令牌。DELETE /v1/me 的密码确认共用它，键为 "delete:" + 账号。
	loginFails *ratelimit.Limiter
}

func NewHandler(
	svc *Service,
	log *slog.Logger,
	maxBytes int64,
	byAddr, refreshLimits, codeLimits *ratelimit.Limiter,
	clientHost func(*http.Request) string,
) *Handler {
	if byAddr == nil {
		byAddr = ratelimit.Disabled()
	}
	if refreshLimits == nil {
		refreshLimits = ratelimit.Disabled()
	}
	if codeLimits == nil {
		codeLimits = ratelimit.Disabled()
	}
	if clientHost == nil {
		clientHost = httpx.RemoteHost
	}
	return &Handler{
		svc: svc, log: log, maxBytes: maxBytes,
		byAddr: byAddr, refreshLimits: refreshLimits, codeLimits: codeLimits,
		clientHost: clientHost, loginFails: ratelimit.Disabled(),
	}
}

// SetLoginFailLimiter 装上按账号的登录失败预算，由 server.New 按配置建好注入。
// 计数键是规范化之后的邮箱（小写、去两端空白）加 "login:" 前缀；删号前的密码
// 确认用 "delete:" 加账号 id，共用同一个限流器，两种失败互相不占额度。
func (h *Handler) SetLoginFailLimiter(l *ratelimit.Limiter) {
	if l == nil {
		l = ratelimit.Disabled()
	}
	h.loginFails = l
}

// loginKey 把邮箱规范成限流键，与服务层登录时的规范化保持一致：同一账号换大小
// 写或带空白提交，扣的是同一个桶。长度截到邮箱上限，避免异常超长的邮箱让限流表
// 的键无限变大。
func loginKey(email string) string {
	key := strings.ToLower(strings.TrimSpace(email))
	if len(key) > 254 {
		key = key[:254]
	}
	return key
}

// cooldownSeconds 把发送验证码的冷却写成 Retry-After 的整秒数。
func (h *Handler) cooldownSeconds() int64 {
	seconds := int64(h.svc.codeCooldown / time.Second)
	if seconds < 1 {
		return 1
	}
	return seconds
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
	if delay := h.byAddr.Take(h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
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
	if delay := h.byAddr.Take(h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.Credentials
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	// 先为本次校验扣除一枚令牌，密码校验结束后仅对失败的凭据保留扣减。
	email := loginKey(string(in.Email))
	refund, delay := h.loginFails.TakeRefundable("login:" + email)
	if delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	t, err := h.svc.Login(r.Context(), string(in.Email), in.Password, optional(in.DeviceName))
	switch {
	case errors.Is(err, ErrInvalidCredentials):
		httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeInvalidCredentials, "")
	case err != nil:
		refund()
		httpx.WriteInternal(w, r, h.log, err)
	default:
		refund()
		httpx.WriteJSON(w, http.StatusOK, tokensJSON(t))
	}
}

func (h *Handler) Refresh(w http.ResponseWriter, r *http.Request) {
	if delay := h.refreshLimits.Take("address:" + h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.PostV1AuthRefreshJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	var accountDelay int64
	t, err := h.svc.refresh(r.Context(), in.RefreshToken, optional(in.RequestId), func(userID string) bool {
		accountDelay = h.refreshLimits.Take("account:" + userID)
		return accountDelay == 0
	})
	switch {
	case errors.Is(err, errRefreshLimited):
		httpx.TooMany(w, r, accountDelay)
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

// RequestEmailVerification 给当前账号的邮箱发验证码。已经确认过的账号直接
// 返回 204，不重复发信；刚发过的返回 429 并给出建议等待秒数。
func (h *Handler) RequestEmailVerification(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	if delay := h.codeLimits.Take("account:" + p.UserID); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	err := h.svc.RequestEmailVerification(r.Context(), p)
	var mailRate mailRateError
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrCodeTooSoon):
		httpx.TooMany(w, r, h.cooldownSeconds())
	case errors.As(err, &mailRate):
		httpx.TooMany(w, r, mailRate.retryAfter)
	case errors.Is(err, ErrMailUnavailable):
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "mail is not configured")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

// ConfirmEmailVerification 校验验证码并把邮箱标为已确认。
func (h *Handler) ConfirmEmailVerification(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	if delay := h.codeLimits.Take("confirm:" + p.UserID); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.PostV1AuthEmailVerifyConfirmJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	err := h.svc.ConfirmEmailVerification(r.Context(), p, in.Code)
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrInvalidCode), errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidCode, "")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

// ForgotPassword 向账号登记的邮箱发送重设验证码。邮箱不存在时也返回 204。
func (h *Handler) ForgotPassword(w http.ResponseWriter, r *http.Request) {
	if delay := h.codeLimits.Take("forgot-address:" + h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.PostV1AuthPasswordForgotJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(string(in.Email)))
	if delay := h.codeLimits.Take("forgot-email:" + email); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	err := h.svc.RequestPasswordReset(r.Context(), email)
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "email must be a plain address")
	case errors.Is(err, ErrCodeTooSoon):
		httpx.TooMany(w, r, h.cooldownSeconds())
	case errors.Is(err, ErrMailUnavailable):
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "mail is not configured")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

// ResetPassword 用验证码重设密码，并作废这个账号的全部会话。
func (h *Handler) ResetPassword(w http.ResponseWriter, r *http.Request) {
	if delay := h.codeLimits.Take("reset-address:" + h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.PostV1AuthPasswordResetJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	err := h.svc.ResetPassword(r.Context(), string(in.Email), in.Code, in.NewPassword)
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "email must be a plain address and password 8 to 128 characters")
	case errors.Is(err, ErrInvalidCode):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidCode, "")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	u, err := h.svc.User(r.Context(), p)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.Me{
		UserId:        u.ID,
		Email:         u.Email,
		EmailVerified: !u.EmailVerifiedAt.IsZero(),
		CreatedAt:     u.CreatedAt,
	})
}

// DeleteMe 删号前要求再输一次密码。密码错误回 401 invalid_credentials 并扣一次
// 按账号的失败预算；只有密码正确才做原有清理并回 204。
func (h *Handler) DeleteMe(w http.ResponseWriter, r *http.Request) {
	if h.checkPassword(w, r, h.svc.DeleteAccount) {
		w.WriteHeader(http.StatusNoContent)
	}
}

// ConfirmPassword 在不可撤销的云端批量删除前重新核对密码。
func (h *Handler) ConfirmPassword(w http.ResponseWriter, r *http.Request) bool {
	return h.checkPassword(w, r, h.svc.VerifyCurrentPassword)
}

func (h *Handler) checkPassword(w http.ResponseWriter, r *http.Request, check func(context.Context, Principal, string) error) bool {
	p := MustPrincipal(r.Context())
	var in api.DeleteV1MeJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return false
	}
	refund, delay := h.loginFails.TakeRefundable("delete:" + p.UserID)
	if delay > 0 {
		httpx.TooMany(w, r, delay)
		return false
	}
	switch err := check(r.Context(), p, in.Password); {
	case err == nil:
		refund()
		return true
	case errors.Is(err, ErrInvalidCredentials):
		httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeInvalidCredentials, "")
	default:
		refund()
		httpx.WriteInternal(w, r, h.log, err)
	}
	return false
}
