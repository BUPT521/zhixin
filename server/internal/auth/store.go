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
	CreatedAt    time.Time
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
	DeleteUser(ctx context.Context, id string) error

	CreateSession(ctx context.Context, s Session) error
	SessionByAccessHash(ctx context.Context, hash string) (Session, error)
	SessionByRefreshHash(ctx context.Context, hash string) (Session, error)
	DeleteSession(ctx context.Context, id string) error
	DeleteUserSessions(ctx context.Context, userID string) error
}

// MemoryStore is a Store kept in process memory.
type MemoryStore struct {
	mu       sync.Mutex
	users    map[string]User
	byEmail  map[string]string
	sessions map[string]Session
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{users: map[string]User{}, byEmail: map[string]string{}, sessions: map[string]Session{}}
}

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

func (m *MemoryStore) DeleteUser(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return ErrNotFound
	}
	delete(m.users, id)
	delete(m.byEmail, u.Email)
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

func (m *MemoryStore) DeleteUserSessions(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, s := range m.sessions {
		if s.UserID == userID {
			delete(m.sessions, id)
		}
	}
	return nil
}
