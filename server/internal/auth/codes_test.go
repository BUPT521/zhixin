package auth

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"
)

// fakeMailer 记下发出的邮件，用例从正文里取出六位验证码。
type fakeMailer struct {
	sent []sentMail
	err  error
}

type sentMail struct {
	To      string
	Subject string
	Body    string
}

func (m *fakeMailer) Send(_ context.Context, to, subject, body string) error {
	if m.err != nil {
		return m.err
	}
	m.sent = append(m.sent, sentMail{To: to, Subject: subject, Body: body})
	return nil
}

func (m *fakeMailer) lastCode(t *testing.T) string {
	t.Helper()
	if len(m.sent) == 0 {
		t.Fatal("没有发出邮件")
	}
	match := regexp.MustCompile(`\b([0-9]{6})\b`).FindStringSubmatch(m.sent[len(m.sent)-1].Body)
	if len(match) != 2 {
		t.Fatalf("邮件正文里没有六位验证码: %q", m.sent[len(m.sent)-1].Body)
	}
	return match[1]
}

func newCodeService(t *testing.T) (*Service, *clock, *fakeMailer) {
	t.Helper()
	s, c := newTestService()
	m := &fakeMailer{}
	s.ConfigureCodes(m, []byte("test-secret"), 10*time.Minute, time.Minute)
	return s, c, m
}

func TestEmailVerificationFlow(t *testing.T) {
	ctx := context.Background()
	s, c, m := newCodeService(t)
	tok, err := s.Register(ctx, "student@example.com", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	p, _ := s.Authenticate(ctx, tok.AccessToken)

	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 || m.sent[0].To != "student@example.com" {
		t.Fatalf("sent %+v", m.sent)
	}
	code := m.lastCode(t)

	// 冷却期内重发被拒绝，但第一次的验证码仍然可用。
	if err := s.RequestEmailVerification(ctx, p); !errors.Is(err, ErrCodeTooSoon) {
		t.Fatalf("second request: %v", err)
	}
	if err := s.ConfirmEmailVerification(ctx, p, "000000"); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("wrong code: %v", err)
	}
	if err := s.ConfirmEmailVerification(ctx, p, code); err != nil {
		t.Fatal(err)
	}
	u, err := s.User(ctx, p)
	if err != nil || u.EmailVerifiedAt.IsZero() {
		t.Fatalf("user not verified: %v %+v", err, u)
	}

	// 已确认的账号不再发信，也不报错。
	c.t = c.t.Add(2 * time.Minute)
	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 {
		t.Fatalf("verified account received another mail: %d", len(m.sent))
	}
}

func TestEmailVerificationCodeExpires(t *testing.T) {
	ctx := context.Background()
	s, c, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	code := m.lastCode(t)
	c.t = c.t.Add(11 * time.Minute)
	if err := s.ConfirmEmailVerification(ctx, p, code); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("expired code accepted: %v", err)
	}
}

func TestEmailVerificationAttemptsAreLimited(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	code := m.lastCode(t)
	for i := 0; i < maxCodeAttempts; i++ {
		if err := s.ConfirmEmailVerification(ctx, p, "999999"); !errors.Is(err, ErrInvalidCode) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	// 次数用完之后正确的验证码也不再接受，必须重新发送。
	if err := s.ConfirmEmailVerification(ctx, p, code); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("code accepted after too many attempts: %v", err)
	}
}

func TestPasswordResetRevokesSessions(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	if err := s.ConfirmEmailVerification(ctx, p, m.lastCode(t)); err != nil {
		t.Fatal(err)
	}

	// 未验证的邮箱不作答复；已验证的邮箱收到重设验证码。
	if err := s.RequestPasswordReset(ctx, "nobody@example.com"); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 {
		t.Fatalf("unknown email received a reset mail: %d", len(m.sent))
	}
	if err := s.RequestPasswordReset(ctx, "student@example.com"); err != nil {
		t.Fatal(err)
	}
	code := m.lastCode(t)
	if err := s.ResetPassword(ctx, "student@example.com", code, "new-password1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "student@example.com", "password1", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("old password still works: %v", err)
	}
	if _, err := s.Authenticate(ctx, tok.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("old session survived a password reset")
	}
	if _, err := s.Login(ctx, "student@example.com", "new-password1", ""); err != nil {
		t.Fatalf("new password does not work: %v", err)
	}
}

// TestPasswordResetCodeSingleUse 核对验证码只能用一次：第二次提交返回
// ErrInvalidCode，密码保持第一次改成的值。
func TestPasswordResetCodeSingleUse(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	if err := s.ConfirmEmailVerification(ctx, p, m.lastCode(t)); err != nil {
		t.Fatal(err)
	}
	if err := s.RequestPasswordReset(ctx, "student@example.com"); err != nil {
		t.Fatal(err)
	}
	code := m.lastCode(t)
	if err := s.ResetPassword(ctx, "student@example.com", code, "new-password1"); err != nil {
		t.Fatal(err)
	}
	if err := s.ResetPassword(ctx, "student@example.com", code, "another-pass1"); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("重放验证码应返回 ErrInvalidCode，得到 %v", err)
	}
	if _, err := s.Login(ctx, "student@example.com", "new-password1", ""); err != nil {
		t.Fatalf("重放不应改动密码: %v", err)
	}
}

func TestPasswordResetRecoversUnverifiedEmail(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	old, err := s.Register(ctx, "student@example.com", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RequestPasswordReset(ctx, "student@example.com"); err != nil {
		t.Fatal(err)
	}
	if err := s.ResetPassword(ctx, "student@example.com", m.lastCode(t), "new-password1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, old.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("old session survives recovery: %v", err)
	}
	fresh, err := s.Login(ctx, "student@example.com", "new-password1", "")
	if err != nil {
		t.Fatal(err)
	}
	principal, err := s.Authenticate(ctx, fresh.AccessToken)
	if err != nil || !principal.EmailVerified {
		t.Fatalf("recovered email is not verified: %+v, %v", principal, err)
	}
}

func TestCodesNeedMailer(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestEmailVerification(ctx, p); !errors.Is(err, ErrMailUnavailable) {
		t.Fatalf("got %v", err)
	}
}

func TestMailFailureDropsCode(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	m.err = errors.New("smtp down")
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestEmailVerification(ctx, p); !errors.Is(err, ErrMailUnavailable) {
		t.Fatalf("got %v", err)
	}
	// 发信失败之后没有留下可用的验证码，下一次重发不受冷却影响。
	m.err = nil
	if err := s.RequestEmailVerification(ctx, p); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 || !strings.Contains(m.sent[0].Body, "验证码") {
		t.Fatalf("sent %+v", m.sent)
	}
}
