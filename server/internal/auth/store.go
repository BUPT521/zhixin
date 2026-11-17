package auth

import (
	"context"
	"errors"
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

	CreateSession(ctx context.Context, s Session) error
	SessionByAccessHash(ctx context.Context, hash string) (Session, error)
	SessionByRefreshHash(ctx context.Context, hash string) (Session, error)
	DeleteSession(ctx context.Context, id string) error
	DeleteUserSessions(ctx context.Context, userID string) error

	SetEmailVerified(ctx context.Context, userID string, at time.Time) error
	UpdatePassword(ctx context.Context, userID, passwordHash string) error

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
	mu       sync.Mutex
	users    map[string]User
	byEmail  map[string]string
	sessions map[string]Session
	codes    map[string]Code
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		users:    map[string]User{},
		byEmail:  map[string]string{},
		sessions: map[string]Session{},
		codes:    map[string]Code{},
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

func (m *MemoryStore) CreateSession(_ context.Context, s Session) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[s.ID] = s
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

func (m *MemoryStore) DeleteSession(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[id]; !ok {
		return ErrNotFound
	}
	delete(m.sessions, id)
	return nil
}
