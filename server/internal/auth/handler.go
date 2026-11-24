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
	// registerGlobal 是整个实例的注册上限，只有一个键：注册在验证登录方式之前就做
	// argon2 并写账号与会话，按来源地址的桶只挡同一个来源，换地址仍能把未验证
	// 的账号灌满库，这个桶给实例一个总量（ADR-0037）。为零值时一律放行。
	registerGlobal *ratelimit.Limiter
	// codeLimits 限制发送验证码与重设密码的尝试：按登录方式、来源地址与联系方式
	// 各记一个桶，防止同一账号被反复发信，也防止换账号刷同一个联系方式。
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
		registerGlobal: ratelimit.Disabled(),
	}
}

// SetLoginFailLimiter 装上按账号的登录失败预算，由 server.New 按配置建好注入。
// 计数键是规范化之后的登录方式值（邮箱小写、去两端空白）加 "login:" 前缀；删号
// 前的密码确认用 "delete:" 加账号 id，共用同一个限流器，两种失败互相不占额度。
func (h *Handler) SetLoginFailLimiter(l *ratelimit.Limiter) {
	if l == nil {
		l = ratelimit.Disabled()
	}
	h.loginFails = l
}

// SetRegisterGlobalLimiter 装上注册的实例级上限，由 server.New 按配置建好注入。
// 传 nil 表示关闭。注册接口公开，在登录方式确认之前就要做一次 argon2 并写入账号
// 与会话；按来源地址的桶只挡同一个来源，换地址仍能把未验证的账号灌满库，所以这
// 里再给整个实例一个总量，超出时在解码请求体与哈希之前返回 429。
func (h *Handler) SetRegisterGlobalLimiter(l *ratelimit.Limiter) {
	if l == nil {
		l = ratelimit.Disabled()
	}
	h.registerGlobal = l
}

// registerGlobalKey 是注册全局桶的键。全局桶只有一个键，与按地址的桶互不共用，
// 因此要单独建一个限流器。
const registerGlobalKey = "global"

// identifierKey 把登录方式的值规范成限流键，与服务层登录时的规范化保持一致：
// 同一账号换大小写或带空白提交，扣的是同一个桶。长度截到契约上限，避免异常
// 超长的值让限流表的键无限变大。
func identifierKey(identifier string) string {
	key := strings.ToLower(strings.TrimSpace(identifier))
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
	// 按地址的桶放行之后，再消耗实例级的一个名额；超过时在解码请求体与哈希之前
	// 返回 429，换地址也不能把未验证的账号灌满库。
	if delay := h.registerGlobal.Take(registerGlobalKey); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.Credentials
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	t, err := h.svc.Register(r.Context(), in.Identifier, in.Password, optional(in.DeviceName))
	switch {
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "identifier must be a plain email address and password 8 to 128 characters")
	case errors.Is(err, ErrIdentifierTaken):
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeIdentifierTaken, "")
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
	identifier := identifierKey(in.Identifier)
	refund, delay := h.loginFails.TakeRefundable("login:" + identifier)
	if delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	t, err := h.svc.Login(r.Context(), in.Identifier, in.Password, optional(in.DeviceName))
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

// RequestIdentityVerification 给账号的某一种登录方式发验证码。已经确认过的直接
// 返回 204，不重复发送；刚发过的返回 429 并给出建议等待秒数；这种登录方式还没有
// 接上发送通道时返回 501。
func (h *Handler) RequestIdentityVerification(w http.ResponseWriter, r *http.Request, identityID string) {
	p := MustPrincipal(r.Context())
	if delay := h.codeLimits.Take("identity:" + identityID); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	err := h.svc.RequestIdentityVerification(r.Context(), p, identityID)
	var sendRate sendRateError
	var instanceRate instanceSendRateError
	var pause mailPauseError
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrNotFound):
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "this identity is not on the account")
	case errors.Is(err, ErrCodeTooSoon):
		httpx.TooMany(w, r, h.cooldownSeconds())
	case errors.As(err, &sendRate):
		httpx.TooMany(w, r, sendRate.retryAfter)
	case errors.As(err, &instanceRate):
		httpx.TooMany(w, r, instanceRate.retryAfter)
	case errors.As(err, &pause):
		httpx.TooMany(w, r, pause.retryAfter)
	case errors.Is(err, ErrSenderUnsupported):
		httpx.WriteProblem(w, r, http.StatusNotImplemented, httpx.CodeNotImplemented, "this identity kind cannot receive a code yet")
	case errors.Is(err, ErrMailUnavailable):
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "mail is not configured")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

// ConfirmIdentityVerification 校验验证码并把那种登录方式标为已确认。
func (h *Handler) ConfirmIdentityVerification(w http.ResponseWriter, r *http.Request, identityID string) {
	p := MustPrincipal(r.Context())
	if delay := h.codeLimits.Take("confirm:" + identityID); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.PostV1MeIdentitiesIdVerificationConfirmJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	err := h.svc.ConfirmIdentityVerification(r.Context(), p, identityID, in.Code)
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrNotFound):
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "this identity is not on the account")
	case errors.Is(err, ErrInvalidCode), errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidCode, "")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

// ForgotPassword 向账号登记的登录方式发送重设验证码。账号不存在时也返回 204。
func (h *Handler) ForgotPassword(w http.ResponseWriter, r *http.Request) {
	if delay := h.codeLimits.Take("forgot-address:" + h.clientHost(r)); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	var in api.PostV1AuthPasswordForgotJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	identifier := identifierKey(in.Identifier)
	if delay := h.codeLimits.Take("forgot-identifier:" + identifier); delay > 0 {
		httpx.TooMany(w, r, delay)
		return
	}
	err := h.svc.RequestPasswordReset(r.Context(), in.Identifier)
	var pause mailPauseError
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "identifier must be a plain email address")
	case errors.Is(err, ErrCodeTooSoon):
		httpx.TooMany(w, r, h.cooldownSeconds())
	case errors.As(err, &pause):
		httpx.TooMany(w, r, pause.retryAfter)
	case errors.Is(err, ErrSenderUnsupported):
		httpx.WriteProblem(w, r, http.StatusNotImplemented, httpx.CodeNotImplemented, "this identity kind cannot receive a code yet")
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
	err := h.svc.ResetPassword(r.Context(), in.Identifier, in.Code, in.NewPassword)
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "identifier must be a plain email address and password 8 to 128 characters")
	case errors.Is(err, ErrInvalidCode):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidCode, "")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}

// Me 返回账号与它的登录方式；顶层的 email 已经去掉，以后加昵称或头像只需在
// 契约里多一个 profile 字段。
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	p := MustPrincipal(r.Context())
	u, identities, err := h.svc.Account(r.Context(), p)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	out := api.Me{
		UserId:     u.ID,
		CreatedAt:  u.CreatedAt,
		Identities: make([]api.Identity, 0, len(identities)),
	}
	for _, ident := range identities {
		out.Identities = append(out.Identities, api.Identity{
			Id:         ident.ID,
			Kind:       api.IdentityKind(ident.Kind),
			Identifier: ident.Identifier,
			Verified:   !ident.VerifiedAt.IsZero(),
		})
	}
	httpx.WriteJSON(w, http.StatusOK, out)
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

// ListAPIKeys 列出当前账号的模型代理密钥。已撤销的也列出，列表里仍然看得到它，
// 从没用过时最近使用时间为空（ADR-0063）。
func (h *Handler) ListAPIKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := h.svc.APIKeys(r.Context(), MustPrincipal(r.Context()))
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	out := apiKeysJSON{Keys: make([]api.ApiKey, 0, len(keys))}
	for _, key := range keys {
		item := api.ApiKey{
			Id: key.ID, Name: key.Name, Prefix: key.Prefix,
			Revoked: key.Revoked, CreatedAt: key.CreatedAt,
		}
		if !key.LastUsedAt.IsZero() {
			used := key.LastUsedAt
			item.LastUsedAt = &used
		}
		out.Keys = append(out.Keys, item)
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// apiKeysJSON 是列表响应的形状；契约里这是一个内联对象，不单独生成类型。
type apiKeysJSON struct {
	Keys []api.ApiKey `json:"keys"`
}

// CreateAPIKey 签发一把模型代理密钥。明文只在这次响应里出现，服务端只留摘要；
// 有效密钥达到上限时回 409，先撤销旧的再签发。
func (h *Handler) CreateAPIKey(w http.ResponseWriter, r *http.Request) {
	var in api.PostV1MeApiKeysJSONRequestBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	key, secret, err := h.svc.CreateAPIKey(r.Context(), MustPrincipal(r.Context()), in.Name)
	switch {
	case errors.Is(err, ErrInvalidInput):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "name must be at most 64 characters")
	case errors.Is(err, ErrKeyLimit):
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "at most 20 active api keys per account")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusCreated, api.ApiKeyCreated{
			Id: key.ID, Name: key.Name, Prefix: key.Prefix,
			Key: secret, CreatedAt: key.CreatedAt,
		})
	}
}

// RevokeAPIKey 撤销一把密钥，之后它立刻不能再调用模型。不属于这个账号、已经
// 撤销或编号不存在都回 404，不区分三种情况。
func (h *Handler) RevokeAPIKey(w http.ResponseWriter, r *http.Request, id string) {
	err := h.svc.RevokeAPIKey(r.Context(), MustPrincipal(r.Context()), id)
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "api key not found")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
