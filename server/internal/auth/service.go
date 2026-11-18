// Package auth implements accounts, password sign-in and opaque bearer tokens.
//
// Access tokens live one hour, refresh tokens thirty days and rotate on every
// refresh; the store keeps only SHA-256 hashes so a database leak does not
// leak usable tokens (ADR-0009).
package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrInvalidInput       = errors.New("auth: invalid input")
	ErrInvalidCredentials = errors.New("auth: invalid email or password")
	ErrInvalidToken       = errors.New("auth: invalid or expired token")
	// ErrInvalidCode 同时覆盖验证码不存在、已过期、已被换掉与输错次数过多，
	// 客户端不需要区分，也不让请求方据此判断邮箱是否存在。
	ErrInvalidCode = errors.New("auth: invalid or expired code")
	// ErrCodeTooSoon 表示同一个账号刚发过验证码，要等冷却结束再发。
	ErrCodeTooSoon = errors.New("auth: a code was sent recently")
	// ErrMailUnavailable 表示服务端没有配置发信，验证码无法送达。
	ErrMailUnavailable = errors.New("auth: mail is not configured")
)

// Tokens is what the client stores after sign-in.
type Tokens struct {
	AccessToken      string    `json:"access_token"`
	RefreshToken     string    `json:"refresh_token"`
	TokenType        string    `json:"token_type"`
	AccessExpiresAt  time.Time `json:"access_expires_at"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at"`
	UserID           string    `json:"user_id"`
}

// Principal is the authenticated caller of a request.
type Principal struct {
	UserID    string
	SessionID string
}

// AccountDeleter removes data owned by the other services before the account
// row disappears. The server wires one function so deleting an account is a
// single idempotent operation rather than one registration per package.
type AccountDeleter func(ctx context.Context, userID string) error

// ActivityRecorder 记录账号在某一天活跃过；实现自己按天去重，见
// retention.Service。登录用户的留存按服务端收到的请求日期统计（ADR-0019），
// 所以每次鉴权成功都要经过它。
type ActivityRecorder interface {
	RecordUserActive(ctx context.Context, userID string) error
}

type Service struct {
	store             Store
	now               func() time.Time
	accessTTL         time.Duration
	refreshTTL        time.Duration
	deleteAccountData AccountDeleter
	activity          ActivityRecorder

	// passwords 限制同时进行的 argon2 计算数；为 nil 时不限制，只有装配处
	// 按内存预算设置之后才生效。
	passwords *PasswordBudget

	// maxSessions 是每个账号保留的会话数上限，新登录超过时删最旧的。默认值
	// 与配置 ZHIXIN_MAX_SESSIONS_PER_USER 的默认值一致，装配处可以覆盖。
	maxSessions int

	// securityLog 记录刷新令牌重放这类安全事件；为 nil 时不记，事件内容只有
	// 账号、会话与请求标识，不含令牌。
	securityLog *slog.Logger

	// 邮箱验证与找回密码。mailer 为 nil 时请求返回 ErrMailUnavailable；
	// codeSecret 用来给六位验证码做 HMAC，避免库里的哈希被穷举。
	mailer       Mailer
	codeSecret   []byte
	codeTTL      time.Duration
	codeCooldown time.Duration
}

const maxCodeAttempts = 5

// defaultMaxSessions 是每个账号保留的会话数上限的默认值，与配置
// ZHIXIN_MAX_SESSIONS_PER_USER 的默认值一致。
const defaultMaxSessions = 20

func NewService(store Store, accessTTL, refreshTTL time.Duration) *Service {
	return &Service{
		store: store, now: time.Now, accessTTL: accessTTL, refreshTTL: refreshTTL,
		maxSessions: defaultMaxSessions,
	}
}

// ConfigureCodes 装上发信与验证码参数；不调用时邮箱验证与找回密码一律返回
// ErrMailUnavailable，登录与其他接口不受影响。secret 必须是稳定的随机字节，
// 服务重启后仍然有效；为空时由调用方生成。
func (s *Service) ConfigureCodes(mailer Mailer, secret []byte, ttl, cooldown time.Duration) {
	s.mailer = mailer
	s.codeSecret = append([]byte(nil), secret...)
	s.codeTTL = ttl
	s.codeCooldown = cooldown
}

// SetAccountDataDeleter registers the one cleanup that runs before the account
// row is removed.
func (s *Service) SetAccountDataDeleter(d AccountDeleter) { s.deleteAccountData = d }

// SetActivityRecorder registers the daily active-day recorder. 不设置时登录用户
// 的活跃不统计，其他功能不受影响。
func (s *Service) SetActivityRecorder(r ActivityRecorder) { s.activity = r }

// SetPasswordBudget 按内存预算（MiB）限制同时进行的 argon2 计算数，注册、登录、
// 重设密码与删号共用这一个上限。不调用时不限制。
func (s *Service) SetPasswordBudget(mib int) {
	if mib <= 0 {
		s.passwords = nil
		return
	}
	s.passwords = NewPasswordBudget(mib)
}

// SetSecurityLog 装上安全事件的日志出口。刷新令牌被重放时写 "refresh token
// reuse"，字段只有 user_id、session_id 与 request_id。
func (s *Service) SetSecurityLog(log *slog.Logger) { s.securityLog = log }

// SetMaxSessions 设定每个账号保留的会话数上限；小于等于零的值忽略，避免把
// 账号锁在“一登录就踢掉自己”的状态里。
func (s *Service) SetMaxSessions(n int) {
	if n > 0 {
		s.maxSessions = n
	}
}

// PruneLoop 启动时清理一次过期会话与验证码，之后每天清理一次，直到 ctx 结束。
// 节奏与 retention.PruneLoop 一致：过期行不影响正确性，清理只控制表的大小。
func (s *Service) PruneLoop(ctx context.Context, store Store, log *slog.Logger) {
	prune := func() {
		if err := store.PruneExpired(ctx, s.now()); err != nil {
			log.Error("prune expired auth rows", slog.String("error", err.Error()))
		}
	}
	prune()
	ticker := time.NewTicker(24 * time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			prune()
		}
	}
}

// hashPassword 在预算内生成哈希。等待名额期间 ctx 结束时直接返回错误，不再
// 开启一次已经没人等的计算。
func (s *Service) hashPassword(ctx context.Context, password string) (string, error) {
	if err := s.passwords.Acquire(ctx); err != nil {
		return "", err
	}
	defer s.passwords.Release()
	return HashPassword(password)
}

// verifyPassword 在预算内核对密码。
func (s *Service) verifyPassword(ctx context.Context, encoded, password string) (bool, error) {
	if err := s.passwords.Acquire(ctx); err != nil {
		return false, err
	}
	defer s.passwords.Release()
	return VerifyPassword(encoded, password)
}

// RecordActivity 在鉴权成功之后记一次账号活跃。错误由调用方记日志，不影响
// 本次请求：统计失败不该让用户的操作失败。
func (s *Service) RecordActivity(ctx context.Context, userID string) error {
	if s.activity == nil {
		return nil
	}
	return s.activity.RecordUserActive(ctx, userID)
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func normalizeEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email || len(email) > 254 {
		return "", ErrInvalidInput
	}
	return email, nil
}

func checkPassword(p string) error {
	if n := utf8.RuneCountInString(p); n < 8 || n > 128 {
		return ErrInvalidInput
	}
	return nil
}

func cleanDevice(name string) string {
	name = strings.TrimSpace(name)
	if utf8.RuneCountInString(name) > 64 {
		name = string([]rune(name)[:64])
	}
	return name
}

// Register creates an account and signs the device in.
func (s *Service) Register(ctx context.Context, email, password, device string) (Tokens, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return Tokens{}, err
	}
	if err := checkPassword(password); err != nil {
		return Tokens{}, err
	}
	hash, err := s.hashPassword(ctx, password)
	if err != nil {
		return Tokens{}, err
	}
	u := User{ID: newID(), Email: email, PasswordHash: hash, CreatedAt: s.now()}
	if err := s.store.CreateUser(ctx, u); err != nil {
		return Tokens{}, err
	}
	return s.issue(ctx, u.ID, device)
}

// Login checks the password and opens a new session for the device.
func (s *Service) Login(ctx context.Context, email, password, device string) (Tokens, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return Tokens{}, ErrInvalidCredentials
	}
	u, err := s.store.UserByEmail(ctx, email)
	if errors.Is(err, ErrNotFound) {
		// Spend the same work as a real check so timing does not reveal
		// which emails are registered.
		_, _ = s.verifyPassword(ctx, dummyHash, password)
		return Tokens{}, ErrInvalidCredentials
	}
	if err != nil {
		return Tokens{}, err
	}
	ok, err := s.verifyPassword(ctx, u.PasswordHash, password)
	if err != nil {
		// 库里的哈希格式或参数不合法时按凭据错误处理：这是库里那一行的问题，
		// 不能因此让这个账号每次登录都回 500，也不能借状态码区分账号是否存在。
		return Tokens{}, ErrInvalidCredentials
	}
	if !ok {
		return Tokens{}, ErrInvalidCredentials
	}
	return s.issue(ctx, u.ID, device)
}

var dummyHash, _ = HashPassword("zhixin-dummy-password")

var errRefreshLimited = errors.New("refresh rate limited")

// refreshGrace 是旧刷新令牌按“同一客户端重试”处理的宽限期。固定 60 秒，重试
// 不延长：宽限期若按每次重试重新计算，复制了令牌的一方可以每隔 59 秒重放一次
// 而永远不被发现。
const refreshGrace = 60 * time.Second

// Refresh rotates the session: the old refresh token stops working at once.
//
// requestID 是客户端为这次刷新生成的标识，重试时原样带上；服务端据此判断旧
// 令牌是同一客户端的重试还是被复制之后的重放。
func (s *Service) Refresh(ctx context.Context, refreshToken, requestID string) (Tokens, error) {
	return s.refresh(ctx, refreshToken, requestID, nil)
}

func (s *Service) refresh(ctx context.Context, refreshToken, requestID string, allowed func(string) bool) (Tokens, error) {
	now := s.now()
	oldHash := hashToken(refreshToken)
	sess, err := s.store.SessionByRefreshHash(ctx, oldHash)
	switch {
	case errors.Is(err, ErrNotFound):
		// 旧令牌已经不在会话表里：可能是已经轮换掉的令牌又出现，交给重放检测。
		return s.handleRefreshReuse(ctx, oldHash, requestID, now)
	case err != nil:
		return Tokens{}, err
	}
	if !now.Before(sess.RefreshExpires) {
		return Tokens{}, ErrInvalidToken
	}
	if allowed != nil && !allowed(sess.UserID) {
		return Tokens{}, errRefreshLimited
	}
	tokens, err := s.rotateSession(ctx, sess.ID, oldHash, sess.UserID, now)
	if err != nil {
		return Tokens{}, err
	}
	// 记下刚用掉的旧令牌摘要：它再出现时，只有宽限期内、request_id 相同的请求
	// 按重试处理，其余按盗用撤销会话。写入失败时整次刷新失败，客户端会重新登录，
	// 不会出现“令牌换了但重放检测缺失”的状态。
	if err := s.store.RecordRefreshUsed(ctx, RefreshUsed{
		TokenHash:           oldHash,
		SessionID:           sess.ID,
		UserID:              sess.UserID,
		RequestID:           requestID,
		RotatedAt:           now,
		GraceUntil:          now.Add(refreshGrace),
		ReplacedAccessHash:  hashToken(tokens.AccessToken),
		ReplacedRefreshHash: hashToken(tokens.RefreshToken),
	}); err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}

// handleRefreshReuse 处理一个已经轮换掉的刷新令牌再次出现。
//
// 宽限期内、request_id 与原记录一致时按同一客户端的重试处理：用同一份记录再
// 轮换一次，宽限截止时间保持不变。其余情况（宽限期已过、request_id 缺失或不同）
// 视为令牌被复制，撤销该账号的全部会话并记一条安全事件。完全没有记录时连账号
// 都无法定位，只回 401。
func (s *Service) handleRefreshReuse(ctx context.Context, oldHash, requestID string, now time.Time) (Tokens, error) {
	used, err := s.store.UsedRefresh(ctx, oldHash)
	if errors.Is(err, ErrNotFound) {
		return Tokens{}, ErrInvalidToken
	}
	if err != nil {
		return Tokens{}, err
	}
	if requestID == "" || requestID != used.RequestID || !now.Before(used.GraceUntil) {
		if s.securityLog != nil {
			// 只记账号、会话与请求标识，不记令牌本身。
			s.securityLog.Warn("refresh token reuse",
				slog.String("user_id", used.UserID),
				slog.String("session_id", used.SessionID),
				slog.String("request_id", requestID),
			)
		}
		if err := s.store.DeleteUserSessions(ctx, used.UserID); err != nil {
			return Tokens{}, err
		}
		return Tokens{}, ErrInvalidToken
	}
	tokens, err := s.rotateSession(ctx, used.SessionID, used.ReplacedRefreshHash, used.UserID, now)
	if err != nil {
		return Tokens{}, err
	}
	// 重试换掉了上一对令牌，旧令牌摘要继续保留同一宽限截止时间，下一对成为新的
	// 可重试对象。
	if err := s.store.RecordRefreshUsed(ctx, RefreshUsed{
		TokenHash:           used.ReplacedRefreshHash,
		SessionID:           used.SessionID,
		UserID:              used.UserID,
		RequestID:           used.RequestID,
		RotatedAt:           now,
		GraceUntil:          used.GraceUntil,
		ReplacedAccessHash:  hashToken(tokens.AccessToken),
		ReplacedRefreshHash: hashToken(tokens.RefreshToken),
	}); err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}

// rotateSession 生成一对新令牌并用 CAS 写回会话。CAS 失败说明这次刷新已经输给
// 并发的另一个请求，按无效令牌处理，不撤销会话。
func (s *Service) rotateSession(ctx context.Context, sessionID, oldRefreshHash, userID string, now time.Time) (Tokens, error) {
	access, refresh := newToken(), newToken()
	accessExpires := now.Add(s.accessTTL)
	refreshExpires := now.Add(s.refreshTTL)
	err := s.store.RotateSession(ctx, sessionID, oldRefreshHash,
		hashToken(access), hashToken(refresh), accessExpires, refreshExpires)
	if errors.Is(err, ErrInvalidToken) {
		return Tokens{}, ErrInvalidToken
	}
	if err != nil {
		return Tokens{}, err
	}
	return Tokens{
		AccessToken:      access,
		RefreshToken:     refresh,
		TokenType:        "Bearer",
		AccessExpiresAt:  accessExpires,
		RefreshExpiresAt: refreshExpires,
		UserID:           userID,
	}, nil
}

// Authenticate resolves an access token.
func (s *Service) Authenticate(ctx context.Context, accessToken string) (Principal, error) {
	sess, err := s.store.SessionByAccessHash(ctx, hashToken(accessToken))
	if errors.Is(err, ErrNotFound) {
		return Principal{}, ErrInvalidToken
	}
	if err != nil {
		return Principal{}, err
	}
	if !s.now().Before(sess.AccessExpires) {
		return Principal{}, ErrInvalidToken
	}
	return Principal{UserID: sess.UserID, SessionID: sess.ID}, nil
}

// Logout ends one session.
func (s *Service) Logout(ctx context.Context, p Principal) error {
	err := s.store.DeleteSession(ctx, p.SessionID)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	return err
}

// User returns the account of p.
func (s *Service) User(ctx context.Context, p Principal) (User, error) {
	return s.store.UserByID(ctx, p.UserID)
}

// RequestEmailVerification sends a six-digit code to the account's own address.
// 已确认的账号直接返回 nil，不重复发信。
func (s *Service) RequestEmailVerification(ctx context.Context, p Principal) error {
	u, err := s.store.UserByID(ctx, p.UserID)
	if err != nil {
		return err
	}
	if !u.EmailVerifiedAt.IsZero() {
		return nil
	}
	return s.issueCode(ctx, u, PurposeVerifyEmail)
}

// ConfirmEmailVerification checks the code and marks the address verified.
func (s *Service) ConfirmEmailVerification(ctx context.Context, p Principal, code string) error {
	if err := s.checkCode(ctx, p.UserID, PurposeVerifyEmail, code); err != nil {
		return err
	}
	if err := s.store.SetEmailVerified(ctx, p.UserID, s.now()); err != nil {
		return err
	}
	return s.store.DeleteCode(ctx, p.UserID, PurposeVerifyEmail)
}

// RequestPasswordReset sends a reset code to a verified address. Unknown or
// unverified addresses are ignored on purpose: the caller always sees the same
// result, so the endpoint cannot be used to find out which emails are registered.
func (s *Service) RequestPasswordReset(ctx context.Context, email string) error {
	email, err := normalizeEmail(email)
	if err != nil {
		return ErrInvalidInput
	}
	u, err := s.store.UserByEmail(ctx, email)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if u.EmailVerifiedAt.IsZero() {
		return nil
	}
	return s.issueCode(ctx, u, PurposeResetPassword)
}

// ResetPassword replaces the password and ends every session of the account,
// including the device that asked for the reset.
func (s *Service) ResetPassword(ctx context.Context, email, code, newPassword string) error {
	email, err := normalizeEmail(email)
	if err != nil {
		return ErrInvalidInput
	}
	if err := checkPassword(newPassword); err != nil {
		return err
	}
	u, err := s.store.UserByEmail(ctx, email)
	if errors.Is(err, ErrNotFound) {
		return ErrInvalidCode
	}
	if err != nil {
		return err
	}
	if u.EmailVerifiedAt.IsZero() {
		return ErrInvalidCode
	}
	if err := s.checkCode(ctx, u.ID, PurposeResetPassword, code); err != nil {
		return err
	}
	hash, err := s.hashPassword(ctx, newPassword)
	if err != nil {
		return err
	}
	// 校验过再交给存储在事务里重新比对一次摘要：验证码用掉、密码换掉、会话
	// 清掉三件事一起提交，两个重试请求不会都成功，也不会出现“密码换了但旧
	// 会话还在”的中间状态。
	err = s.store.ResetPassword(ctx, u.ID, PurposeResetPassword,
		s.hashCode(u.ID, PurposeResetPassword, strings.TrimSpace(code)), hash, s.now())
	if errors.Is(err, ErrInvalidCode) {
		return ErrInvalidCode
	}
	return err
}

// issueCode 生成一枚六位验证码并交给发信。发信失败时删除刚写入的记录，
// 避免用户收到“已发送”却永远等不到邮件。
func (s *Service) issueCode(ctx context.Context, u User, purpose string) error {
	if s.mailer == nil || len(s.codeSecret) == 0 {
		return ErrMailUnavailable
	}
	existing, err := s.store.Code(ctx, u.ID, purpose)
	switch {
	case err == nil && s.now().Sub(existing.CreatedAt) < s.codeCooldown:
		return ErrCodeTooSoon
	case err != nil && !errors.Is(err, ErrNotFound):
		return err
	}
	code, err := newCode()
	if err != nil {
		return err
	}
	now := s.now()
	c := Code{
		UserID:    u.ID,
		Purpose:   purpose,
		CodeHash:  s.hashCode(u.ID, purpose, code),
		ExpiresAt: now.Add(s.codeTTL),
		CreatedAt: now,
	}
	if err := s.store.PutCode(ctx, c); err != nil {
		return err
	}
	if err := s.mailer.Send(ctx, u.Email, codeSubject(purpose), codeBody(purpose, code, s.codeTTL)); err != nil {
		_ = s.store.DeleteCode(ctx, u.ID, purpose)
		return fmt.Errorf("%w: %v", ErrMailUnavailable, err)
	}
	return nil
}

// checkCode 校验验证码；过期、输错达到上限与不存在都归为 ErrInvalidCode。
func (s *Service) checkCode(ctx context.Context, userID, purpose, code string) error {
	code = strings.TrimSpace(code)
	if len(code) != 6 {
		// 仍然计一次尝试，避免用长度试探绕过次数上限。
		_, _ = s.store.IncrementCodeAttempts(ctx, userID, purpose)
		return ErrInvalidCode
	}
	c, err := s.store.Code(ctx, userID, purpose)
	if errors.Is(err, ErrNotFound) {
		return ErrInvalidCode
	}
	if err != nil {
		return err
	}
	if !s.now().Before(c.ExpiresAt) {
		_ = s.store.DeleteCode(ctx, userID, purpose)
		return ErrInvalidCode
	}
	attempts, err := s.store.IncrementCodeAttempts(ctx, userID, purpose)
	if err != nil {
		return err
	}
	if attempts > maxCodeAttempts {
		_ = s.store.DeleteCode(ctx, userID, purpose)
		return ErrInvalidCode
	}
	want := []byte(c.CodeHash)
	got := []byte(s.hashCode(userID, purpose, code))
	if subtle.ConstantTimeCompare(want, got) != 1 {
		return ErrInvalidCode
	}
	return nil
}

func (s *Service) hashCode(userID, purpose, code string) string {
	mac := hmac.New(sha256.New, s.codeSecret)
	mac.Write([]byte(userID))
	mac.Write([]byte{0})
	mac.Write([]byte(purpose))
	mac.Write([]byte{0})
	mac.Write([]byte(code))
	return hex.EncodeToString(mac.Sum(nil))
}

func newCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func codeSubject(purpose string) string {
	if purpose == PurposeResetPassword {
		return "知新 · 重设密码验证码"
	}
	return "知新 · 验证邮箱验证码"
}

func codeBody(purpose, code string, ttl time.Duration) string {
	action := "确认邮箱"
	if purpose == PurposeResetPassword {
		action = "重设密码"
	}
	minutes := int(ttl / time.Minute)
	if minutes < 1 {
		minutes = 1
	}
	return fmt.Sprintf(
		"你正在%s。验证码是 %s，%d 分钟内有效。\n\n"+
			"如果不是你本人操作，忽略这封邮件即可，账号不会被改动。\n",
		action, code, minutes,
	)
}

// DeleteAccount removes every piece of server-side data for the account: the
// caller-supplied data first, then the user row. Sessions, sync log, backups and
// usage go with it through the schema's ON DELETE CASCADE. Any cleanup failure
// stops before the user row is removed, so the request can be retried.
//
// 删号不可撤销，所以先核对一次密码：拿着别人设备上的访问令牌不能直接把账号
// 删掉。密码校验与登录共用同一个内存预算与哈希校验规则。
func (s *Service) DeleteAccount(ctx context.Context, p Principal, password string) error {
	u, err := s.store.UserByID(ctx, p.UserID)
	if errors.Is(err, ErrNotFound) {
		return ErrInvalidCredentials
	}
	if err != nil {
		return err
	}
	ok, err := s.verifyPassword(ctx, u.PasswordHash, password)
	if err != nil || !ok {
		return ErrInvalidCredentials
	}
	if s.deleteAccountData != nil {
		if err := s.deleteAccountData(ctx, p.UserID); err != nil {
			return err
		}
	}
	return s.store.DeleteUser(ctx, p.UserID)
}

func (s *Service) issue(ctx context.Context, userID, device string) (Tokens, error) {
	now := s.now()
	access, refresh := newToken(), newToken()
	sess := Session{
		ID:             newID(),
		UserID:         userID,
		DeviceName:     cleanDevice(device),
		AccessHash:     hashToken(access),
		RefreshHash:    hashToken(refresh),
		AccessExpires:  now.Add(s.accessTTL),
		RefreshExpires: now.Add(s.refreshTTL),
		CreatedAt:      now,
	}
	if err := s.store.CreateSession(ctx, sess, s.maxSessions); err != nil {
		return Tokens{}, err
	}
	return Tokens{
		AccessToken:      access,
		RefreshToken:     refresh,
		TokenType:        "Bearer",
		AccessExpiresAt:  sess.AccessExpires,
		RefreshExpiresAt: sess.RefreshExpires,
		UserID:           userID,
	}, nil
}
