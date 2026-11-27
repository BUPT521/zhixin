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
	if _, err := s.Register(ctx, "student@example.com", "password2", ""); !errors.Is(err, ErrIdentifierTaken) {
		t.Fatalf("duplicate identifier: %v", err)
	}
	p, err := s.Authenticate(ctx, reg.AccessToken)
	if err != nil || p.UserID != reg.UserID {
		t.Fatalf("authenticate: %v %+v", err, p)
	}
	if _, err := s.Login(ctx, "student@example.com", "nope-nope", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("wrong password: %v", err)
	}
	if _, err := s.Login(ctx, "nobody@example.com", "password1", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("unknown identifier: %v", err)
	}
	if _, err := s.Login(ctx, "STUDENT@example.com", "password1", ""); err != nil {
		t.Fatalf("login: %v", err)
	}
}

func TestRegisterValidates(t *testing.T) {
	s, _ := newTestService()
	for _, tc := range []struct{ identifier, pw string }{
		{"not-an-email", "password1"},
		{"Name <a@b.c>", "password1"},
		{"a@b.c", "short"},
		// 手机号与微信的识别已经留好，但登录入口还没有接，注册一律拒绝。
		{"+8613800138000", "password1"},
	} {
		if _, err := s.Register(context.Background(), tc.identifier, tc.pw, ""); !errors.Is(err, ErrInvalidInput) {
			t.Errorf("%q/%q: got %v", tc.identifier, tc.pw, err)
		}
	}
}

func TestRegisterRestrictsEmailDomains(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	s.SetRegisterEmailDomains([]string{"bupt.cn"})

	for _, identifier := range []string{
		"outsider@example.com",
		"student@bupt.cn.example.com",
	} {
		if _, err := s.Register(ctx, identifier, "password1", ""); !errors.Is(err, ErrEmailDomainNotAllowed) {
			t.Fatalf("%q: got %v, want ErrEmailDomainNotAllowed", identifier, err)
		}
		// 被挡下的注册不写账号行，换一个合法后缀仍然可以注册。
		if _, err := s.store.UserByIdentifier(ctx, KindEmail, identifier); !errors.Is(err, ErrNotFound) {
			t.Fatalf("%q 被拒绝后不应写入账号：%v", identifier, err)
		}
	}
	if _, err := s.Register(ctx, " Student@BUPT.cn ", "password1", ""); err != nil {
		t.Fatalf("大写与空白应规范化后放行：%v", err)
	}

	// 限制只作用于注册：在收紧之前登记的其他邮箱仍然可以登录。
	old, _ := newTestService()
	if _, err := old.Register(ctx, "old@example.com", "password1", ""); err != nil {
		t.Fatal(err)
	}
	old.SetRegisterEmailDomains([]string{"bupt.cn"})
	if _, err := old.Login(ctx, "old@example.com", "password1", ""); err != nil {
		t.Fatalf("已有账号登录不应受后缀限制：%v", err)
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

	second, err := s.Refresh(ctx, first.RefreshToken, "req-1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, second.AccessToken); err != nil {
		t.Fatal(err)
	}
	// 同一 request_id 在宽限期内再出现按重试处理，两次拿到的令牌都可继续用。
	retry, err := s.Refresh(ctx, first.RefreshToken, "req-1")
	if err != nil {
		t.Fatalf("同一客户端的重试应当成功: %v", err)
	}
	if _, err := s.Authenticate(ctx, retry.AccessToken); err != nil {
		t.Fatalf("重试返回的访问令牌应当可用: %v", err)
	}
	if _, err := s.Refresh(ctx, retry.RefreshToken, "req-2"); err != nil {
		t.Fatalf("重试返回的刷新令牌应当可用: %v", err)
	}

	c.t = c.t.Add(31 * 24 * time.Hour)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-3"); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("expired refresh token accepted")
	}
}

func TestDeleteAccountRunsCleanupFirst(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	tok, _ := s.Register(ctx, "a@b.cn", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)

	// 密码不对直接回凭据错误，账号与清理都不动。
	if err := s.DeleteAccount(ctx, p, "wrong-password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("错密码应返回凭据错误，得到 %v", err)
	}
	if _, err := s.Authenticate(ctx, tok.AccessToken); err != nil {
		t.Fatal("密码错误的删号请求不应影响账号")
	}

	boom := errors.New("backup store down")
	s.SetAccountDataDeleter(func(context.Context, string) error { return boom })
	if err := s.DeleteAccount(ctx, p, "password1"); !errors.Is(err, boom) {
		t.Fatalf("got %v", err)
	}
	if _, err := s.Authenticate(ctx, tok.AccessToken); err != nil {
		t.Fatal("account must survive a failed cleanup so deletion can be retried")
	}

	s.deleteAccountData = nil
	var cleaned string
	s.SetAccountDataDeleter(func(_ context.Context, id string) error { cleaned = id; return nil })
	if err := s.DeleteAccount(ctx, p, "password1"); err != nil {
		t.Fatal(err)
	}
	if cleaned != p.UserID {
		t.Fatal("cleanup not called")
	}
	if _, err := s.Authenticate(ctx, tok.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("session survived account deletion")
	}
}
