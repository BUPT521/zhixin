package auth

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/ratelimit"
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
	s.ConfigureCodes(NewSenders(m), []byte("test-secret"), 10*time.Minute, time.Minute)
	return s, c, m
}

// createEmailAccount 在内存存储里写入账号与一条邮箱登录方式，返回这条登录方式。
// 用例都用邮箱，与“代码现在只写 email”一致。
func createEmailAccount(t *testing.T, st *MemoryStore, u User, email string) Identity {
	t.Helper()
	ident := Identity{
		ID:         u.ID + "-email",
		UserID:     u.ID,
		Kind:       KindEmail,
		Identifier: email,
		CreatedAt:  u.CreatedAt,
	}
	if err := st.CreateAccount(context.Background(), u, ident); err != nil {
		t.Fatalf("create account %s: %v", u.ID, err)
	}
	return ident
}

// identityID 返回账号名下唯一的登录方式编号。
func identityID(t *testing.T, s *Service, p Principal) string {
	t.Helper()
	_, identities, err := s.Account(context.Background(), p)
	if err != nil {
		t.Fatal(err)
	}
	if len(identities) != 1 {
		t.Fatalf("应只有一条登录方式，得到 %+v", identities)
	}
	return identities[0].ID
}

func TestIdentityVerificationFlow(t *testing.T) {
	ctx := context.Background()
	s, c, m := newCodeService(t)
	tok, err := s.Register(ctx, "student@example.com", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)

	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 || m.sent[0].To != "student@example.com" {
		t.Fatalf("sent %+v", m.sent)
	}
	code := m.lastCode(t)

	// 冷却期内重发被拒绝，但第一次的验证码仍然可用。
	if err := s.RequestIdentityVerification(ctx, p, id); !errors.Is(err, ErrCodeTooSoon) {
		t.Fatalf("second request: %v", err)
	}
	if err := s.ConfirmIdentityVerification(ctx, p, id, "000000"); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("wrong code: %v", err)
	}
	if err := s.ConfirmIdentityVerification(ctx, p, id, code); err != nil {
		t.Fatal(err)
	}
	// 确认之后重新鉴权，Principal 上的“至少一种登录方式已确认”为真。
	fresh, err := s.Authenticate(ctx, tok.AccessToken)
	if err != nil || !fresh.ContactVerified {
		t.Fatalf("contact not verified: %v %+v", err, fresh)
	}

	// 已确认的账号不再发信，也不报错。
	c.t = c.t.Add(2 * time.Minute)
	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 {
		t.Fatalf("verified identity received another mail: %d", len(m.sent))
	}
}

// TestIdentityVerificationRejectsForeignIdentity 核对验证接口只认当前账号名下的
// 登录方式：别人的编号按不存在处理，不把那条联系方式带出去。
func TestIdentityVerificationRejectsForeignIdentity(t *testing.T) {
	ctx := context.Background()
	s, _, _ := newCodeService(t)
	tok, err := s.Register(ctx, "owner@example.com", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	if err := s.RequestIdentityVerification(ctx, p, "not-on-this-account"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("got %v", err)
	}
}

func TestIdentityVerificationCodeExpires(t *testing.T) {
	ctx := context.Background()
	s, c, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)
	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	code := m.lastCode(t)
	c.t = c.t.Add(11 * time.Minute)
	if err := s.ConfirmIdentityVerification(ctx, p, id, code); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("expired code accepted: %v", err)
	}
}

func TestIdentityVerificationAttemptsAreLimited(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)
	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	code := m.lastCode(t)
	for i := 0; i < maxCodeAttempts; i++ {
		if err := s.ConfirmIdentityVerification(ctx, p, id, "999999"); !errors.Is(err, ErrInvalidCode) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	// 次数用完之后正确的验证码也不再接受，必须重新发送。
	if err := s.ConfirmIdentityVerification(ctx, p, id, code); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("code accepted after too many attempts: %v", err)
	}
}

func TestPasswordResetRevokesSessions(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)
	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	if err := s.ConfirmIdentityVerification(ctx, p, id, m.lastCode(t)); err != nil {
		t.Fatal(err)
	}

	// 未登记的登录方式不作答复；已登记的收到重设验证码。
	if err := s.RequestPasswordReset(ctx, "nobody@example.com"); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 {
		t.Fatalf("unknown identifier received a reset mail: %d", len(m.sent))
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
	id := identityID(t, s, p)
	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	if err := s.ConfirmIdentityVerification(ctx, p, id, m.lastCode(t)); err != nil {
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

// TestPasswordResetConfirmsUnverifiedIdentity 核对重设密码顺带确认收到验证码的
// 那种登录方式：收到验证码本身就是这条联系方式属于本人的证据。
func TestPasswordResetConfirmsUnverifiedIdentity(t *testing.T) {
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
	if err != nil || !principal.ContactVerified {
		t.Fatalf("recovered identity is not verified: %+v, %v", principal, err)
	}
}

// TestUnsupportedIdentityKind 核对没有接上发送通道的登录方式返回“暂不支持”，
// 并且不留下可用的验证码；库里验证码的 user_id 也允许为空。
func TestUnsupportedIdentityKind(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	err := s.issueCode(ctx, "", PurposeVerifyContact, KindPhone, "+8613800138000")
	if !errors.Is(err, ErrSenderUnsupported) {
		t.Fatalf("got %v", err)
	}
	if len(m.sent) != 0 {
		t.Fatalf("不支持的方式不应发出消息: %+v", m.sent)
	}
	if _, err := s.store.Code(ctx, PurposeVerifyContact, KindPhone, "+8613800138000"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unsupported kind left a code: %v", err)
	}
}

func TestCodesNeedMailer(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)
	if err := s.RequestIdentityVerification(ctx, p, id); !errors.Is(err, ErrMailUnavailable) {
		t.Fatalf("got %v", err)
	}
}

func TestMailFailureDropsCode(t *testing.T) {
	ctx := context.Background()
	s, _, m := newCodeService(t)
	m.err = errors.New("smtp down")
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)
	if err := s.RequestIdentityVerification(ctx, p, id); !errors.Is(err, ErrMailUnavailable) {
		t.Fatalf("got %v", err)
	}
	// 发信失败之后没有留下可用的验证码，下一次重发不受冷却影响。
	m.err = nil
	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	if len(m.sent) != 1 || !strings.Contains(m.sent[0].Body, "验证码") {
		t.Fatalf("sent %+v", m.sent)
	}
}

// TestSendLimitKeyedByKindAndIdentifier 核对发信预算按 kind:identifier 计：换了
// 用途但收信地址相同，仍然共用同一个桶。
func TestSendLimitKeyedByKindAndIdentifier(t *testing.T) {
	ctx := context.Background()
	s, c, _ := newCodeService(t)
	s.SetSendLimiter(ratelimit.New(rate.Limit(0), 1, 0))
	tok, _ := s.Register(ctx, "student@example.com", "password1", "")
	p, _ := s.Authenticate(ctx, tok.AccessToken)
	id := identityID(t, s, p)

	if err := s.RequestIdentityVerification(ctx, p, id); err != nil {
		t.Fatal(err)
	}
	// 过了冷却期再换一个用途：同一地址共用一份预算，重设密码这一步按“已受理”
	// 返回，不发信也不报错。
	c.t = c.t.Add(2 * time.Minute)
	if err := s.RequestPasswordReset(ctx, "student@example.com"); err != nil {
		t.Fatalf("第二个用途应共用同一份预算并静默受理，得到 %v", err)
	}
	// 换回确认登录方式：冷却期已过，剩下的是用尽的发信预算。
	if err := s.RequestIdentityVerification(ctx, p, id); !errors.As(err, new(sendRateError)) {
		t.Fatalf("预算用尽应返回发信预算错误，得到 %v", err)
	}
}
