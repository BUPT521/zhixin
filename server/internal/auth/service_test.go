package auth

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newTestService() (*Service, *clock) {
	c := &clock{t: time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)}
	s := NewService(NewMemoryStore(), time.Hour, 30*24*time.Hour)
	s.now = c.now
	return s, c
}

func TestPasswordRoundTrip(t *testing.T) {
	h, err := HashPassword("correct horse")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$") {
		t.Fatalf("hash format %q", h)
	}
	if ok, _ := VerifyPassword(h, "correct horse"); !ok {
		t.Fatal("right password rejected")
	}
	if ok, _ := VerifyPassword(h, "wrong horse"); ok {
		t.Fatal("wrong password accepted")
	}
	if _, err := VerifyPassword("$bcrypt$x", "x"); err == nil {
		t.Fatal("malformed hash accepted")
	}
}

func TestRegisterLoginAuthenticate(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()

	reg, err := s.Register(ctx, " Student@Example.com ", "password1", "PLK110")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Register(ctx, "student@example.com", "password2", ""); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("duplicate email: %v", err)
	}
	p, err := s.Authenticate(ctx, reg.AccessToken)
	if err != nil || p.UserID != reg.UserID {
		t.Fatalf("authenticate: %v %+v", err, p)
	}
	if _, err := s.Login(ctx, "student@example.com", "nope-nope", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("wrong password: %v", err)
	}
	if _, err := s.Login(ctx, "nobody@example.com", "password1", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("unknown email: %v", err)
	}
	if _, err := s.Login(ctx, "STUDENT@example.com", "password1", ""); err != nil {
		t.Fatalf("login: %v", err)
	}
}

func TestRegisterValidates(t *testing.T) {
	s, _ := newTestService()
	for _, tc := range []struct{ email, pw string }{
		{"not-an-email", "password1"},
		{"Name <a@b.c>", "password1"},
		{"a@b.c", "short"},
	} {
		if _, err := s.Register(context.Background(), tc.email, tc.pw, ""); !errors.Is(err, ErrInvalidInput) {
			t.Errorf("%q/%q: got %v", tc.email, tc.pw, err)
		}
	}
}

func TestAccessTokenExpires(t *testing.T) {
	ctx := context.Background()
	s, c := newTestService()
	tok, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(time.Hour)
	if _, err := s.Authenticate(ctx, tok.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("expired access token accepted: %v", err)
	}
}

func TestRefreshRotates(t *testing.T) {
	ctx := context.Background()
	s, c := newTestService()
	first, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(2 * time.Hour)

	second, err := s.Refresh(ctx, first.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Refresh(ctx, first.RefreshToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("old refresh token reused")
	}
	if _, err := s.Authenticate(ctx, second.AccessToken); err != nil {
		t.Fatal(err)
	}

	c.t = c.t.Add(31 * 24 * time.Hour)
	if _, err := s.Refresh(ctx, second.RefreshToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("expired refresh token accepted")
	}
}

func TestDeleteAccountRunsCleanupFirst(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	tok, _ := s.Register(ctx, "a@b.cn", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)

	boom := errors.New("backup store down")
	s.OnAccountDelete(func(context.Context, string) error { return boom })
	if err := s.DeleteAccount(ctx, p); !errors.Is(err, boom) {
		t.Fatalf("got %v", err)
	}
	if _, err := s.Authenticate(ctx, tok.AccessToken); err != nil {
		t.Fatal("account must survive a failed cleanup so deletion can be retried")
	}

	s.deleters = nil
	var cleaned string
	s.OnAccountDelete(func(_ context.Context, id string) error { cleaned = id; return nil })
	if err := s.DeleteAccount(ctx, p); err != nil {
		t.Fatal(err)
	}
	if cleaned != p.UserID {
		t.Fatal("cleanup not called")
	}
	if _, err := s.Authenticate(ctx, tok.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("session survived account deletion")
	}
}
