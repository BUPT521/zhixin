// Package auth implements accounts, password sign-in and opaque bearer tokens.
//
// Access tokens live one hour, refresh tokens thirty days and rotate on every
// refresh; the store keeps only SHA-256 hashes so a database leak does not
// leak usable tokens (ADR-0009).
package auth

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrInvalidInput       = errors.New("auth: invalid input")
	ErrInvalidCredentials = errors.New("auth: invalid email or password")
	ErrInvalidToken       = errors.New("auth: invalid or expired token")
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

// AccountDeleter removes one kind of per-account data (sync log, backups,
// usage). Every data-owning package registers one so account deletion
// cannot silently leave learning data behind on the server.
type AccountDeleter func(ctx context.Context, userID string) error

type Service struct {
	store      Store
	now        func() time.Time
	accessTTL  time.Duration
	refreshTTL time.Duration
	deleters   []AccountDeleter
}

func NewService(store Store, accessTTL, refreshTTL time.Duration) *Service {
	return &Service{store: store, now: time.Now, accessTTL: accessTTL, refreshTTL: refreshTTL}
}

// OnAccountDelete registers cleanup for data owned by other packages.
func (s *Service) OnAccountDelete(d AccountDeleter) { s.deleters = append(s.deleters, d) }

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
			// Another refresh consumed the token after this request read it.
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

// DeleteAccount removes every piece of server-side data for the account,
// then the sessions and the user row. Any cleanup failure stops before the
// user row is removed, so the request can be retried.
func (s *Service) DeleteAccount(ctx context.Context, p Principal) error {
	for _, d := range s.deleters {
		if err := d(ctx, p.UserID); err != nil {
			return err
		}
	}
	if err := s.store.DeleteUserSessions(ctx, p.UserID); err != nil {
		return err
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
