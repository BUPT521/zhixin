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

type Service struct {
	store             Store
	now               func() time.Time
	accessTTL         time.Duration
	refreshTTL        time.Duration
	deleteAccountData AccountDeleter

	// 邮箱验证与找回密码。mailer 为 nil 时请求返回 ErrMailUnavailable；
	// codeSecret 用来给六位验证码做 HMAC，避免库里的哈希被穷举。
	mailer       Mailer
	codeSecret   []byte
	codeTTL      time.Duration
	codeCooldown time.Duration
}

const maxCodeAttempts = 5

func NewService(store Store, accessTTL, refreshTTL time.Duration) *Service {
	return &Service{store: store, now: time.Now, accessTTL: accessTTL, refreshTTL: refreshTTL}
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
	hash, err := HashPassword(password)
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
		_, _ = VerifyPassword(dummyHash, password)
		return Tokens{}, ErrInvalidCredentials
	}
	if err != nil {
		return Tokens{}, err
	}
	ok, err := VerifyPassword(u.PasswordHash, password)
	if err != nil {
		return Tokens{}, err
	}
	if !ok {
		return Tokens{}, ErrInvalidCredentials
	}
	return s.issue(ctx, u.ID, device)
}

var dummyHash, _ = HashPassword("zhixin-dummy-password")

var errRefreshLimited = errors.New("refresh rate limited")

// Refresh rotates the session: the old refresh token stops working at once.
func (s *Service) Refresh(ctx context.Context, refreshToken string) (Tokens, error) {
	return s.refresh(ctx, refreshToken, nil)
}

func (s *Service) refresh(ctx context.Context, refreshToken string, allowed func(string) bool) (Tokens, error) {
	old, err := s.store.SessionByRefreshHash(ctx, hashToken(refreshToken))
	if errors.Is(err, ErrNotFound) {
		return Tokens{}, ErrInvalidToken
	}
	if err != nil {
		return Tokens{}, err
	}
	if !s.now().Before(old.RefreshExpires) {
		return Tokens{}, ErrInvalidToken
	}
	if allowed != nil && !allowed(old.UserID) {
		return Tokens{}, errRefreshLimited
	}
	if err := s.store.DeleteSession(ctx, old.ID); err != nil {
		if errors.Is(err, ErrNotFound) {
			return Tokens{}, ErrInvalidToken
		}
		return Tokens{}, err
	}
	return s.issue(ctx, old.UserID, old.DeviceName)
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
	hash, err := HashPassword(newPassword)
	if err != nil {
		return err
	}
	if err := s.store.UpdatePassword(ctx, u.ID, hash); err != nil {
		return err
	}
	if err := s.store.DeleteUserSessions(ctx, u.ID); err != nil {
		return err
	}
	return s.store.DeleteCode(ctx, u.ID, PurposeResetPassword)
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
func (s *Service) DeleteAccount(ctx context.Context, p Principal) error {
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
	if err := s.store.CreateSession(ctx, sess); err != nil {
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
