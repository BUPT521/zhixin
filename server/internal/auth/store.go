package auth

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// User is an account. One account holds one person's learning data (ADR-0008).
type User struct {
	ID           string
	Email        string
	PasswordHash string
	// EmailVerifiedAt 为零值表示还没有确认邮箱；确认之后找回密码才有收信地址。
	EmailVerifiedAt time.Time
	CreatedAt       time.Time
}

// Code purposes. The values are also the auth_code.purpose check constraint.
const (
	PurposeVerifyEmail   = "verify_email"
	PurposeResetPassword = "reset_password"
)

// Code is one active email verification or password reset code. Only the
// HMAC-SHA256 of the six-digit code is stored; the plain code exists only in
// the message sent to the user.
type Code struct {
	UserID    string
	Purpose   string
	CodeHash  string
	ExpiresAt time.Time
	Attempts  int
	CreatedAt time.Time
}

// Session is one signed-in device. Only token hashes are stored.
type Session struct {
	ID             string
	UserID         string
	DeviceName     string
	AccessHash     string
	RefreshHash    string
	AccessExpires  time.Time
	RefreshExpires time.Time
	CreatedAt      time.Time
}

// RefreshUsed 是一次已经轮换掉的刷新令牌摘要。旧令牌再次出现时，服务层用它
// 判断是同一客户端的重试还是令牌被复制：宽限期内且 request_id 一致算重试，
// 其余算盗用。只存摘要，不存令牌本身。
type RefreshUsed struct {
	TokenHash           string
	SessionID           string
	UserID              string
	RequestID           string
	RotatedAt           time.Time
	GraceUntil          time.Time
	ReplacedAccessHash  string
	ReplacedRefreshHash string
}

var (
	ErrNotFound   = errors.New("auth: not found")
	ErrEmailTaken = errors.New("auth: email already registered")
)

// Store persists users and sessions. The PostgreSQL implementation follows
// internal/store/schema.sql; MemoryStore is for development and tests.
type Store interface {
	CreateUser(ctx context.Context, u User) error
	UserByEmail(ctx context.Context, email string) (User, error)
	UserByID(ctx context.Context, id string) (User, error)
	// DeleteUser removes the account and, like the schema's ON DELETE CASCADE,
	// its sessions.
	DeleteUser(ctx context.Context, id string) error

	// CreateSession 保存一条会话。maxPerUser 是这个账号保留的会话数上限，
	// 超出时在同一个事务或锁内先删最旧的再插入，并发登录也守得住。
	CreateSession(ctx context.Context, s Session, maxPerUser int) error
	SessionByAccessHash(ctx context.Context, hash string) (Session, error)
	SessionByRefreshHash(ctx context.Context, hash string) (Session, error)
	// RotateSession 用 CAS 换掉一条会话的两个令牌摘要：只有当前的 refresh_hash
	// 仍等于 oldRefreshHash 时才更新。并发刷新因此只有一个成功，其余返回
	// ErrInvalidToken。
	RotateSession(ctx context.Context, id, oldRefreshHash, newAccessHash, newRefreshHash string, accessExpires, refreshExpires time.Time) error
	// UsedRefresh 返回已经轮换掉的刷新令牌摘要；没有记录时返回 ErrNotFound。
	UsedRefresh(ctx context.Context, tokenHash string) (RefreshUsed, error)
	// RecordRefreshUsed 保存已经轮换掉的刷新令牌摘要；同一个摘要重复写入时
	// 更新“本次发出的令牌”，宽限截止时间与 request_id 保留第一次的值。
	RecordRefreshUsed(ctx context.Context, u RefreshUsed) error
	DeleteSession(ctx context.Context, id string) error
	DeleteUserSessions(ctx context.Context, userID string) error
	// PruneExpired 删除刷新令牌已过期的会话与已过期的验证码；仍在有效期内的
	// 行不受影响。过期数据留在库里不影响正确性，清理只控制表的大小。
	PruneExpired(ctx context.Context, now time.Time) error

	SetEmailVerified(ctx context.Context, userID string, at time.Time) error
	UpdatePassword(ctx context.Context, userID, passwordHash string) error
	// ResetPassword 在一个事务里用掉验证码、换密码并删除该账号的全部会话，
	// 三步要么一起成功，要么都不发生。验证码要同时匹配 purpose、code_hash
	// 且未过期才算用掉，否则返回 ErrInvalidCode。
	ResetPassword(ctx context.Context, userID, purpose, expectedCodeHash, newPasswordHash string, now time.Time) error

	// PutCode replaces the active code for one account and purpose.
	PutCode(ctx context.Context, c Code) error
	// Code returns ErrNotFound when no code is active.
	Code(ctx context.Context, userID, purpose string) (Code, error)
	// IncrementCodeAttempts adds one failed attempt and returns the new count.
	IncrementCodeAttempts(ctx context.Context, userID, purpose string) (int, error)
	DeleteCode(ctx context.Context, userID, purpose string) error
}

// MemoryStore is a Store kept in process memory.
type MemoryStore struct {
	mu          sync.Mutex
	users       map[string]User
	byEmail     map[string]string
	sessions    map[string]Session
	codes       map[string]Code
	refreshUsed map[string]RefreshUsed
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		users:       map[string]User{},
		byEmail:     map[string]string{},
		sessions:    map[string]Session{},
		codes:       map[string]Code{},
		refreshUsed: map[string]RefreshUsed{},
	}
}

func codeKey(userID, purpose string) string { return userID + "\x00" + purpose }

func (m *MemoryStore) CreateUser(_ context.Context, u User) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byEmail[u.Email]; ok {
		return ErrEmailTaken
	}
	m.users[u.ID] = u
	m.byEmail[u.Email] = u.ID
	return nil
}

func (m *MemoryStore) UserByEmail(_ context.Context, email string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.byEmail[email]
	if !ok {
		return User{}, ErrNotFound
	}
	return m.users[id], nil
}

func (m *MemoryStore) UserByID(_ context.Context, id string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return User{}, ErrNotFound
	}
	return u, nil
}

// DeleteUser 删除账号及其会话，与 schema.sql 的 ON DELETE CASCADE 一致。
func (m *MemoryStore) DeleteUser(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return ErrNotFound
	}
	delete(m.users, id)
	delete(m.byEmail, u.Email)
	for sid, s := range m.sessions {
		if s.UserID == id {
			delete(m.sessions, sid)
		}
	}
	for key, c := range m.codes {
		if c.UserID == id {
			delete(m.codes, key)
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.UserID == id })
	return nil
}

func (m *MemoryStore) DeleteUserSessions(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for sid, s := range m.sessions {
		if s.UserID == userID {
			delete(m.sessions, sid)
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.UserID == userID })
	return nil
}

func (m *MemoryStore) SetEmailVerified(_ context.Context, userID string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[userID]
	if !ok {
		return ErrNotFound
	}
	u.EmailVerifiedAt = at
	m.users[userID] = u
	return nil
}

func (m *MemoryStore) UpdatePassword(_ context.Context, userID, passwordHash string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[userID]
	if !ok {
		return ErrNotFound
	}
	u.PasswordHash = passwordHash
	m.users[userID] = u
	return nil
}

// ResetPassword 在同一把锁里用完验证码、换密码、删会话，三步要么都成要么都不成。
func (m *MemoryStore) ResetPassword(_ context.Context, userID, purpose, expectedCodeHash, newPasswordHash string, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := codeKey(userID, purpose)
	c, ok := m.codes[key]
	if !ok || c.CodeHash != expectedCodeHash || !now.Before(c.ExpiresAt) {
		return ErrInvalidCode
	}
	u, ok := m.users[userID]
	if !ok {
		return ErrNotFound
	}
	delete(m.codes, key)
	u.PasswordHash = newPasswordHash
	m.users[userID] = u
	for sid, s := range m.sessions {
		if s.UserID == userID {
			delete(m.sessions, sid)
		}
	}
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.UserID == userID })
	return nil
}

func (m *MemoryStore) PutCode(_ context.Context, c Code) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.codes[codeKey(c.UserID, c.Purpose)] = c
	return nil
}

func (m *MemoryStore) Code(_ context.Context, userID, purpose string) (Code, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.codes[codeKey(userID, purpose)]
	if !ok {
		return Code{}, ErrNotFound
	}
	return c, nil
}

func (m *MemoryStore) IncrementCodeAttempts(_ context.Context, userID, purpose string) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := codeKey(userID, purpose)
	c, ok := m.codes[key]
	if !ok {
		return 0, ErrNotFound
	}
	c.Attempts++
	m.codes[key] = c
	return c.Attempts, nil
}

func (m *MemoryStore) DeleteCode(_ context.Context, userID, purpose string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.codes, codeKey(userID, purpose))
	return nil
}

// CreateSession 先按上限删掉最旧的会话再插入，两步在同一把锁内完成，同一个
// 账号的并发登录不会把会话数推过上限。
func (m *MemoryStore) CreateSession(_ context.Context, s Session, maxPerUser int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if maxPerUser < 1 {
		maxPerUser = 1
	}
	m.trimSessionsLocked(s.UserID, maxPerUser-1)
	m.sessions[s.ID] = s
	return nil
}

// trimSessionsLocked 保留账号最新的 keep 条会话，删掉更旧的。调用方已持有锁。
func (m *MemoryStore) trimSessionsLocked(userID string, keep int) {
	if keep < 0 {
		keep = 0
	}
	type owned struct {
		id      string
		created time.Time
	}
	list := make([]owned, 0, len(m.sessions))
	for id, s := range m.sessions {
		if s.UserID == userID {
			list = append(list, owned{id: id, created: s.CreatedAt})
		}
	}
	if len(list) <= keep {
		return
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].created.Equal(list[j].created) {
			return list[i].id < list[j].id
		}
		return list[i].created.Before(list[j].created)
	})
	for _, o := range list[:len(list)-keep] {
		delete(m.sessions, o.id)
	}
}

// PruneExpired 删除刷新令牌已经过期的会话与过期的验证码。
func (m *MemoryStore) PruneExpired(_ context.Context, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	gone := map[string]bool{}
	for id, s := range m.sessions {
		if !now.Before(s.RefreshExpires) {
			delete(m.sessions, id)
			gone[id] = true
		}
	}
	if len(gone) > 0 {
		m.purgeUsedLocked(func(u RefreshUsed) bool { return gone[u.SessionID] })
	}
	for key, c := range m.codes {
		if !now.Before(c.ExpiresAt) {
			delete(m.codes, key)
		}
	}
	return nil
}

func (m *MemoryStore) findSession(match func(Session) bool) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		if match(s) {
			return s, nil
		}
	}
	return Session{}, ErrNotFound
}

func (m *MemoryStore) SessionByAccessHash(_ context.Context, hash string) (Session, error) {
	return m.findSession(func(s Session) bool { return s.AccessHash == hash })
}

func (m *MemoryStore) SessionByRefreshHash(_ context.Context, hash string) (Session, error) {
	return m.findSession(func(s Session) bool { return s.RefreshHash == hash })
}

// RotateSession 在锁内做 CAS：refresh_hash 还是旧摘要才换成新的一对。
func (m *MemoryStore) RotateSession(_ context.Context, id, oldRefreshHash, newAccessHash, newRefreshHash string, accessExpires, refreshExpires time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if !ok || s.RefreshHash != oldRefreshHash {
		return ErrInvalidToken
	}
	s.AccessHash = newAccessHash
	s.RefreshHash = newRefreshHash
	s.AccessExpires = accessExpires
	s.RefreshExpires = refreshExpires
	m.sessions[id] = s
	return nil
}

func (m *MemoryStore) UsedRefresh(_ context.Context, tokenHash string) (RefreshUsed, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.refreshUsed[tokenHash]
	if !ok {
		return RefreshUsed{}, ErrNotFound
	}
	return u, nil
}

// RecordRefreshUsed 保存已经轮换掉的刷新令牌摘要。同一个摘要重复写入时只更新
// “本次发出的令牌”，宽限截止时间与 request_id 保留第一次的值，重试因此不会
// 延长宽限期，连续重试也仍然能按记录里的最新摘要再轮换。
func (m *MemoryStore) RecordRefreshUsed(_ context.Context, u RefreshUsed) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if old, ok := m.refreshUsed[u.TokenHash]; ok {
		old.RotatedAt = u.RotatedAt
		old.ReplacedAccessHash = u.ReplacedAccessHash
		old.ReplacedRefreshHash = u.ReplacedRefreshHash
		m.refreshUsed[u.TokenHash] = old
		return nil
	}
	m.refreshUsed[u.TokenHash] = u
	return nil
}

// purgeUsedLocked 删掉不再需要判断重放的旧令牌记录，与 PostgreSQL 实现里
// session_refresh_used 的 ON DELETE CASCADE 一致。调用方已持有锁。
func (m *MemoryStore) purgeUsedLocked(match func(RefreshUsed) bool) {
	for hash, u := range m.refreshUsed {
		if match(u) {
			delete(m.refreshUsed, hash)
		}
	}
}

func (m *MemoryStore) DeleteSession(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[id]; !ok {
		return ErrNotFound
	}
	delete(m.sessions, id)
	m.purgeUsedLocked(func(u RefreshUsed) bool { return u.SessionID == id })
	return nil
}
