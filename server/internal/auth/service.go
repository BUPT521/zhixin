// Package auth implements accounts, password sign-in and opaque bearer tokens.
//
// Access tokens live one hour, refresh tokens thirty days and rotate on every
// refresh; the store keeps only SHA-256 hashes so a database leak does not
// leak usable tokens (ADR-0009).
//
// 账号与登录方式是分开的两张表：密码在 app_user，邮箱这类联系方式在
// user_identity，验证码按登录方式保存（ADR-0038）。
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
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/BUPT521/zhixin/server/internal/periodic"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

var (
	ErrInvalidInput       = errors.New("auth: invalid input")
	ErrInvalidCredentials = errors.New("auth: invalid identifier or password")
	ErrInvalidToken       = errors.New("auth: invalid or expired token")
	// ErrInvalidCode 同时覆盖验证码不存在、已过期、已被换掉与输错次数过多，
	// 客户端不需要区分，也不让请求方据此判断账号是否存在。
	ErrInvalidCode = errors.New("auth: invalid or expired code")
	// ErrCodeTooSoon 表示这种登录方式刚发过验证码，要等冷却结束再发。
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
	// ContactVerified 表示这个账号至少有一种登录方式已经确认；托管额度与云端
	// 写入按它判断，不再只看邮箱（ADR-0038）。
	ContactVerified bool
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

	// unverifiedKeep 是没有任何已验证登录方式的账号的保留期：注册之后超过这段
	// 时间仍未确认的账号由每日清理删除。默认值与配置
	// ZHIXIN_UNVERIFIED_KEEP_DAYS 的默认值一致，装配处可以覆盖。
	unverifiedKeep time.Duration

	// securityLog 记录刷新令牌重放这类安全事件；为 nil 时不记，事件内容只有
	// 账号、会话与请求标识，不含令牌。
	securityLog *slog.Logger

	// 验证码按登录方式分发：senders 为 nil 时请求返回 ErrMailUnavailable；
	// codeSecret 用来给六位验证码做 HMAC，避免库里的哈希被穷举。
	senders      CodeSender
	codeSecret   []byte
	codeTTL      time.Duration
	codeCooldown time.Duration
	sendLimits   *ratelimit.Limiter
	// globalSendLimits 是实例级的发信上限，防止换地址与换收件地址刷 SMTP 配额。
	globalSendLimits *ratelimit.Limiter
}

type sendRateError struct{ retryAfter int64 }

func (sendRateError) Error() string { return "auth: recipient code budget exhausted" }

// instanceSendRateError 表示实例的发信总量用完了，与某一个收件地址无关。
type instanceSendRateError struct{ retryAfter int64 }

func (instanceSendRateError) Error() string { return "auth: instance mail budget exhausted" }

// mailPauseError 表示发信通道正在暂停，值里带还要等多久。
type mailPauseError struct{ retryAfter int64 }

func (mailPauseError) Error() string { return "auth: mail sender is paused" }

// mailPause 取发信器当前的暂停时长，写成 Retry-After 的整秒数。
func (s *Service) mailPause() int64 {
	p, ok := s.senders.(*Senders)
	if !ok {
		return 0
	}
	delay := p.PausedFor()
	if delay <= 0 {
		return 0
	}
	seconds := int64((delay + time.Second - 1) / time.Second)
	if seconds < 1 {
		seconds = 1
	}
	return seconds
}

const maxCodeAttempts = 5

// defaultMaxSessions 是每个账号保留的会话数上限的默认值，与配置
// ZHIXIN_MAX_SESSIONS_PER_USER 的默认值一致。
const defaultMaxSessions = 20

// defaultUnverifiedKeep 是未验证账号的默认保留期，与配置
// ZHIXIN_UNVERIFIED_KEEP_DAYS 的默认值一致。
const defaultUnverifiedKeep = 7 * 24 * time.Hour

// 手机号的形状：可选的加号加 6 至 20 位数字。识别出来之后注册与登录仍然拒绝，
// 因为手机号的登录入口还没有接（ADR-0038）。
var phoneIdentifier = regexp.MustCompile(`^\+?[0-9]{6,20}$`)

func NewService(store Store, accessTTL, refreshTTL time.Duration) *Service {
	return &Service{
		store: store, now: time.Now, accessTTL: accessTTL, refreshTTL: refreshTTL,
		maxSessions: defaultMaxSessions, unverifiedKeep: defaultUnverifiedKeep,
	}
}

// ConfigureCodes 装上验证码的发送分发与参数；不调用时确认登录方式与找回密码
// 一律返回 ErrMailUnavailable，登录与其他接口不受影响。secret 必须是稳定的随机
// 字节，服务重启后仍然有效；为空时由调用方生成。
func (s *Service) ConfigureCodes(senders CodeSender, secret []byte, ttl, cooldown time.Duration) {
	s.senders = senders
	s.codeSecret = append([]byte(nil), secret...)
	s.codeTTL = ttl
	s.codeCooldown = cooldown
}

// SetSendLimiter 装上按登录方式的收信预算，键是 kind:identifier，两种用途共用
// 同一个桶，确认登录方式与找回密码不会各自多拿一份额度。
func (s *Service) SetSendLimiter(limiter *ratelimit.Limiter) { s.sendLimits = limiter }

// SetGlobalSendLimiter 装上整个实例的发信上限，只有一个键：换大量没有注册过的
// 邮箱地址就能绕开按地址与按收件地址的桶，这个桶给 SMTP 服务商的配额兜底。
// 按预算扣在生成与写入验证码之前，超限时不留下记录。传 nil 表示关闭。
func (s *Service) SetGlobalSendLimiter(limiter *ratelimit.Limiter) {
	if limiter == nil {
		limiter = ratelimit.Disabled()
	}
	s.globalSendLimits = limiter
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

// SetUnverifiedKeep 设定未验证账号的保留天数；小于等于零的值忽略，沿用默认
// 7 天。每日清理按注册时间早于 now-days、且没有任何一种已验证登录方式的账号
// 删除，忽略零值也避免把保留期配成 0 之后“注册即删”。
func (s *Service) SetUnverifiedKeep(days int) {
	if days > 0 {
		s.unverifiedKeep = time.Duration(days) * 24 * time.Hour
	}
}

// PruneLoop 启动时清理一次过期会话、过期验证码与超过保留期的未验证账号，之后
// 每天清理一次，直到 ctx 结束。节奏与 retention.PruneLoop 一致：过期行不影响
// 正确性，清理只控制表的大小；未验证账号超过保留期后删除，释放联系方式与账号行。
func (s *Service) PruneLoop(ctx context.Context, store Store, log *slog.Logger) {
	prune := func() {
		now := s.now()
		if err := store.PruneExpired(ctx, now, now.Add(-max(s.refreshTTL, refreshGrace))); err != nil {
			log.Error("prune expired auth rows", slog.String("error", err.Error()))
		}
		// 没有任何一种已验证登录方式的账号按保留期删除：注册是公开入口，账号行
		// 与 argon2 哈希在确认之前就已经写入，超过保留期仍未确认的行没有云端
		// 数据，删掉可以释放联系方式与账号表空间（ADR-0037）。删除行数大于零时
		// 记一条，便于核对清理量；失败留到下一次每日清理重试。装了安全日志出口时
		// 写那里，否则写每日清理的日志，事件里只有删除的行数，不含账号与联系方式。
		removed, err := store.PruneUnverified(ctx, now.Add(-s.unverifiedKeep))
		switch {
		case err != nil:
			log.Error("prune unverified auth users", slog.String("error", err.Error()))
		case removed > 0:
			if s.securityLog != nil {
				s.securityLog.Info("pruned unverified auth users", slog.Int64("users", removed))
			} else {
				log.Info("pruned unverified auth users", slog.Int64("users", removed))
			}
		}
	}
	periodic.Run(ctx, time.Hour*24, prune)
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

// parseIdentifier 按值的形状识别登录方式并做规范化：含 @ 的按邮箱，符合
// 手机号形状的按手机号，其余是无效输入。微信的 identifier 来自开放平台回调，
// 不会出现在用户提交的登录请求里，所以这里识别不出 wechat。
func parseIdentifier(raw string) (kind, identifier string, err error) {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch {
	case value == "":
		return "", "", ErrInvalidInput
	case strings.Contains(value, "@"):
		email, err := normalizeEmail(value)
		if err != nil {
			return "", "", err
		}
		return KindEmail, email, nil
	case phoneIdentifier.MatchString(value):
		return KindPhone, value, nil
	default:
		return "", "", ErrInvalidInput
	}
}

// signInIdentifier 是注册与登录接受的登录方式。现在只有邮箱有入口：手机号与
// 微信各自要先接一个登录入口，识别出来之后在这里拒绝；入口就位时只改这一处。
func signInIdentifier(raw string) (kind, identifier string, err error) {
	kind, identifier, err = parseIdentifier(raw)
	if err != nil {
		return "", "", err
	}
	if kind != KindEmail {
		return "", "", ErrInvalidInput
	}
	return kind, identifier, nil
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

// Register creates an account with one login identity and signs the device in.
func (s *Service) Register(ctx context.Context, rawIdentifier, password, device string) (Tokens, error) {
	kind, identifier, err := signInIdentifier(rawIdentifier)
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
	now := s.now()
	u := User{ID: newID(), PasswordHash: hash, CreatedAt: now}
	ident := Identity{
		ID: newID(), UserID: u.ID, Kind: kind, Identifier: identifier, CreatedAt: now,
	}
	if err := s.store.CreateAccount(ctx, u, ident); err != nil {
		return Tokens{}, err
	}
	return s.issue(ctx, u.ID, device, hash)
}

// Login checks the password of the account that owns the identifier and opens a
// new session for the device.
func (s *Service) Login(ctx context.Context, rawIdentifier, password, device string) (Tokens, error) {
	kind, identifier, err := signInIdentifier(rawIdentifier)
	if err != nil {
		// Spend the same work as a real check so timing does not reveal which
		// identifiers are registered.
		_, _ = s.verifyPassword(ctx, dummyHash, password)
		return Tokens{}, ErrInvalidCredentials
	}
	u, err := s.store.UserByIdentifier(ctx, kind, identifier)
	if errors.Is(err, ErrNotFound) {
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
	return s.issue(ctx, u.ID, device, u.PasswordHash)
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
	// 轮换与重放记录在存储的同一个事务或同一把锁里完成：客户端要么拿到新令牌
	// 且旧摘要已经记下，要么两步都没有发生、旧令牌仍然可用。两步之间不再有请求
	// 取消或写库失败留下的中间状态。
	return s.rotateSessionAndRecord(ctx, sess.ID, oldHash, sess.UserID, now, RefreshUsed{
		TokenHash:  oldHash,
		SessionID:  sess.ID,
		UserID:     sess.UserID,
		RequestID:  requestID,
		RotatedAt:  now,
		GraceUntil: now.Add(refreshGrace),
	})
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
	// 重试换掉上一对令牌：存储会在同一个事务里把原旧令牌与刚用掉的令牌都记成
	// 指向新的一对，宽限截止时间沿用原记录。同一客户端在宽限期内连续重试因此都
	// 能拿到新令牌，而宽限期不会因为重试变长；这次轮换与两条记录一起成功或一起
	// 不发生，不存在只换令牌、旧摘要没记下的窗口。
	return s.rotateSessionAndRecord(ctx, used.SessionID, used.ReplacedRefreshHash, used.UserID, now, RefreshUsed{
		TokenHash:  oldHash,
		SessionID:  used.SessionID,
		UserID:     used.UserID,
		RequestID:  used.RequestID,
		RotatedAt:  now,
		GraceUntil: used.GraceUntil,
	})
}

// rotateSessionAndRecord 生成一对新令牌，交给存储把轮换与重放记录放在同一个事务
// 或同一把锁里完成。used 是要写入记录的旧摘要：正常刷新时它就是这次消费的
// oldRefreshHash；宽限期内的重试里它是客户端提交的更早摘要，存储会同时记下它
// 与这次消费的当前摘要。记录里“本次发出的令牌”由存储按新摘要填好。CAS 失败
// 说明这次刷新已经输给并发的另一个请求，按无效令牌处理，不撤销会话。
func (s *Service) rotateSessionAndRecord(ctx context.Context, sessionID, oldRefreshHash, userID string, now time.Time, used RefreshUsed) (Tokens, error) {
	access, refresh := newToken(), newToken()
	accessExpires := now.Add(s.accessTTL)
	refreshExpires := now.Add(s.refreshTTL)
	err := s.store.RotateSessionAndRecord(ctx, sessionID, oldRefreshHash,
		hashToken(access), hashToken(refresh), accessExpires, refreshExpires, used)
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
	return Principal{
		UserID:          sess.UserID,
		SessionID:       sess.ID,
		ContactVerified: sess.ContactVerified,
	}, nil
}

// Logout ends one session.
func (s *Service) Logout(ctx context.Context, p Principal) error {
	err := s.store.DeleteSession(ctx, p.SessionID)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	return err
}

// Account 返回账号与它的登录方式，供 GET /v1/me 使用。
func (s *Service) Account(ctx context.Context, p Principal) (User, []Identity, error) {
	u, err := s.store.UserByID(ctx, p.UserID)
	if err != nil {
		return User{}, nil, err
	}
	identities, err := s.store.Identities(ctx, p.UserID)
	if err != nil {
		return User{}, nil, err
	}
	return u, identities, nil
}

// RequestIdentityVerification sends a six-digit code to one of the account's own
// login identities. 已经确认过的直接返回 nil，不重复发送。
func (s *Service) RequestIdentityVerification(ctx context.Context, p Principal, identityID string) error {
	ident, err := s.store.Identity(ctx, p.UserID, identityID)
	if err != nil {
		return err
	}
	if !ident.VerifiedAt.IsZero() {
		return nil
	}
	return s.issueCode(ctx, p.UserID, PurposeVerifyContact, ident.Kind, ident.Identifier)
}

// ConfirmIdentityVerification checks the code and marks that identity verified.
func (s *Service) ConfirmIdentityVerification(ctx context.Context, p Principal, identityID, code string) error {
	ident, err := s.store.Identity(ctx, p.UserID, identityID)
	if err != nil {
		return err
	}
	if err := s.checkCode(ctx, PurposeVerifyContact, ident.Kind, ident.Identifier, code); err != nil {
		return err
	}
	if err := s.store.SetIdentityVerified(ctx, p.UserID, ident.ID, s.now()); err != nil {
		return err
	}
	return s.store.DeleteCode(ctx, PurposeVerifyContact, ident.Kind, ident.Identifier)
}

// RequestPasswordReset sends a code to the account that owns the identifier. The
// recipient can recover an account even if that identity was never confirmed.
func (s *Service) RequestPasswordReset(ctx context.Context, rawIdentifier string) error {
	kind, identifier, err := parseIdentifier(rawIdentifier)
	if err != nil {
		return ErrInvalidInput
	}
	if s.senders == nil || len(s.codeSecret) == 0 {
		return ErrMailUnavailable
	}
	u, err := s.store.UserByIdentifier(ctx, kind, identifier)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	err = s.issueCode(ctx, u.ID, PurposeResetPassword, kind, identifier)
	// 冷却、收件地址预算、实例总量与发信暂停都按“已受理”返回：重设密码的入口是
	// 公开的，回得不一样就能试出邮箱是否注册过，也试出限流的状态。
	var paused mailPauseError
	if errors.Is(err, ErrCodeTooSoon) || errors.As(err, new(sendRateError)) ||
		errors.As(err, new(instanceSendRateError)) || errors.As(err, &paused) {
		return nil
	}
	return err
}

// ResetPassword replaces the password, confirms the identity that received the
// code and ends every session of the account, including the device that asked
// for the reset.
func (s *Service) ResetPassword(ctx context.Context, rawIdentifier, code, newPassword string) error {
	kind, identifier, err := parseIdentifier(rawIdentifier)
	if err != nil {
		return ErrInvalidInput
	}
	if err := checkPassword(newPassword); err != nil {
		return err
	}
	ident, err := s.store.IdentityByIdentifier(ctx, kind, identifier)
	if errors.Is(err, ErrNotFound) {
		return ErrInvalidCode
	}
	if err != nil {
		return err
	}
	if err := s.checkCode(ctx, PurposeResetPassword, kind, identifier, code); err != nil {
		return err
	}
	hash, err := s.hashPassword(ctx, newPassword)
	if err != nil {
		return err
	}
	// 校验过再交给存储在事务里重新比对一次摘要：验证码用掉、密码换掉、那种登录
	// 方式确认、会话清掉四件事一起提交，两个重试请求不会都成功，也不会出现
	// “密码换了但旧会话还在”的中间状态。
	err = s.store.ResetPassword(ctx, PasswordReset{
		UserID:          ident.UserID,
		IdentityID:      ident.ID,
		Purpose:         PurposeResetPassword,
		Kind:            kind,
		Identifier:      identifier,
		ExpectedHash:    s.hashCode(PurposeResetPassword, kind, identifier, strings.TrimSpace(code)),
		NewPasswordHash: hash,
		Now:             s.now(),
	})
	if errors.Is(err, ErrInvalidCode) {
		return ErrInvalidCode
	}
	return err
}

// issueCode 生成一枚六位验证码并交给按登录方式分发的发送接口。发信失败时删除
// 刚写入的记录，避免用户收到“已发送”却永远等不到消息；这种登录方式还没有接上
// 发送通道时返回 ErrSenderUnsupported。收信预算的键是 kind:identifier。
func (s *Service) issueCode(ctx context.Context, userID, purpose, kind, identifier string) error {
	if s.senders == nil || len(s.codeSecret) == 0 {
		return ErrMailUnavailable
	}
	capable := s.senders.CanSend(kind)
	if !capable {
		// 邮箱是对外承诺过的通道，没配置按“暂时不可用”返回，运维看日志能认出是
		// 配置问题；手机号与微信是还没有接上发送方，答案只能是“暂不支持”。
		if kind == KindEmail {
			return ErrMailUnavailable
		}
		return ErrSenderUnsupported
	}
	existing, err := s.store.Code(ctx, purpose, kind, identifier)
	switch {
	case err == nil && s.now().Sub(existing.CreatedAt) < s.codeCooldown:
		return ErrCodeTooSoon
	case err != nil && !errors.Is(err, ErrNotFound):
		return err
	}
	if delay := s.mailPause(); delay > 0 {
		return mailPauseError{retryAfter: delay}
	}
	if s.sendLimits != nil {
		if delay := s.sendLimits.Take(kind + ":" + identifier); delay > 0 {
			return sendRateError{retryAfter: delay}
		}
	}
	if s.globalSendLimits != nil {
		if delay := s.globalSendLimits.TakeOne(); delay > 0 {
			return instanceSendRateError{retryAfter: delay}
		}
	}
	code, err := newCode()
	if err != nil {
		return err
	}
	now := s.now()
	c := Code{
		Purpose:    purpose,
		Kind:       kind,
		Identifier: identifier,
		UserID:     userID,
		CodeHash:   s.hashCode(purpose, kind, identifier, code),
		ExpiresAt:  now.Add(s.codeTTL),
		CreatedAt:  now,
	}
	if err := s.store.PutCode(ctx, c); err != nil {
		return err
	}
	err = s.senders.SendCode(ctx, kind, identifier,
		codeSubject(purpose, kind), codeBody(purpose, kind, code, s.codeTTL))
	if err != nil {
		_ = s.store.DeleteCode(ctx, purpose, kind, identifier)
		if errors.Is(err, ErrSenderUnsupported) {
			return ErrSenderUnsupported
		}
		return fmt.Errorf("%w: %v", ErrMailUnavailable, err)
	}
	return nil
}

// checkCode 校验验证码；过期、输错达到上限与不存在都归为 ErrInvalidCode。
func (s *Service) checkCode(ctx context.Context, purpose, kind, identifier, code string) error {
	code = strings.TrimSpace(code)
	if len(code) != 6 {
		// 仍然计一次尝试，避免用长度试探绕过次数上限。
		_, _ = s.store.IncrementCodeAttempts(ctx, purpose, kind, identifier)
		return ErrInvalidCode
	}
	c, err := s.store.Code(ctx, purpose, kind, identifier)
	if errors.Is(err, ErrNotFound) {
		return ErrInvalidCode
	}
	if err != nil {
		return err
	}
	if !s.now().Before(c.ExpiresAt) {
		_ = s.store.DeleteCode(ctx, purpose, kind, identifier)
		return ErrInvalidCode
	}
	attempts, err := s.store.IncrementCodeAttempts(ctx, purpose, kind, identifier)
	if err != nil {
		return err
	}
	if attempts > maxCodeAttempts {
		_ = s.store.DeleteCode(ctx, purpose, kind, identifier)
		return ErrInvalidCode
	}
	want := []byte(c.CodeHash)
	got := []byte(s.hashCode(purpose, kind, identifier, code))
	if subtle.ConstantTimeCompare(want, got) != 1 {
		return ErrInvalidCode
	}
	return nil
}

// hashCode 把用途、登录方式与验证码一起做 HMAC：换了登录方式或用途之后同一枚
// 验证码对不上，库里也没有能直接穷举的明文。
func (s *Service) hashCode(purpose, kind, identifier, code string) string {
	mac := hmac.New(sha256.New, s.codeSecret)
	for _, part := range []string{purpose, kind, identifier, code} {
		mac.Write([]byte(part))
		mac.Write([]byte{0})
	}
	return hex.EncodeToString(mac.Sum(nil))
}

func newCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func codeSubject(purpose, kind string) string {
	if purpose == PurposeResetPassword {
		return "知新 · 重设密码验证码"
	}
	switch kind {
	case KindPhone:
		return "知新 · 验证手机号验证码"
	case KindWechat:
		return "知新 · 验证微信验证码"
	default:
		return "知新 · 验证邮箱验证码"
	}
}

func codeBody(purpose, kind, code string, ttl time.Duration) string {
	action := "确认邮箱"
	switch {
	case purpose == PurposeResetPassword:
		action = "重设密码"
	case kind == KindPhone:
		action = "确认手机号"
	case kind == KindWechat:
		action = "确认微信"
	}
	minutes := int(ttl / time.Minute)
	if minutes < 1 {
		minutes = 1
	}
	return fmt.Sprintf(
		"你正在%s。验证码是 %s，%d 分钟内有效。\n\n"+
			"如果不是你本人操作，忽略这条消息即可，账号不会被改动。\n",
		action, code, minutes,
	)
}

// VerifyCurrentPassword 在不可撤销的操作之前重新核对一次密码：拿着别人设备上
// 的访问令牌不能直接把账号删掉，也不能清空云端数据。密码校验与登录共用同一个
// 内存预算与哈希校验规则。
func (s *Service) VerifyCurrentPassword(ctx context.Context, p Principal, password string) error {
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
	return nil
}

// DeleteAccount removes every piece of server-side data for the account: the
// caller-supplied data first, then the user row. Identities, sessions, sync log,
// backups and usage go with it through the schema's ON DELETE CASCADE. Any
// cleanup failure stops before the user row is removed, so the request can be
// retried.
func (s *Service) DeleteAccount(ctx context.Context, p Principal, password string) error {
	if err := s.VerifyCurrentPassword(ctx, p, password); err != nil {
		return err
	}
	if s.deleteAccountData != nil {
		if err := s.deleteAccountData(ctx, p.UserID); err != nil {
			return err
		}
	}
	return s.store.DeleteUser(ctx, p.UserID)
}

func (s *Service) issue(ctx context.Context, userID, device, checkedHash string) (Tokens, error) {
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
	if err := s.store.CreateSession(ctx, sess, s.maxSessions, checkedHash); err != nil {
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
