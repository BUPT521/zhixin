package auth

import (
	"bytes"
	"context"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"net/textproto"
	"strings"
	"testing"
	"time"
)

func TestCodeEmailMIME(t *testing.T) {
	for _, tc := range []struct {
		purpose, title, action string
	}{
		{PurposeVerifyContact, "验证邮箱", "确认邮箱"},
		{PurposeResetPassword, "重设密码", "重设密码"},
	} {
		t.Run(tc.purpose, func(t *testing.T) {
			const code = "012345"
			const to = "student@example.test"
			mailer := &fakeMailer{}
			if err := NewSenders(mailer).SendCode(t.Context(), KindEmail, to, tc.purpose, code, 17*time.Minute); err != nil {
				t.Fatal(err)
			}
			if len(mailer.sent) != 1 || mailer.sent[0].To != to {
				t.Fatalf("应当向 %s 发送一封邮件", to)
			}
			raw, err := encodeMail("noreply@example.test", to, mailer.sent[0].MailMessage)
			if err != nil {
				t.Fatal(err)
			}
			message, err := mail.ReadMessage(bytes.NewReader(raw))
			if err != nil {
				t.Fatal(err)
			}
			subject, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
			if err != nil || subject != "知新 · "+tc.title+"验证码" {
				t.Fatalf("邮件主题为 %q，解码错误为 %v", subject, err)
			}
			mediaType, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
			if err != nil || mediaType != "multipart/alternative" || params["boundary"] == "" {
				t.Fatalf("邮件应包含可替换的正文：%s (%v)", mediaType, err)
			}
			parts := multipart.NewReader(message.Body, params["boundary"])
			for _, wantType := range []string{"text/plain", "text/html"} {
				part, err := parts.NextPart()
				if err != nil {
					t.Fatal(err)
				}
				mediaType, params, err := mime.ParseMediaType(part.Header.Get("Content-Type"))
				if err != nil || mediaType != wantType || !strings.EqualFold(params["charset"], "UTF-8") {
					t.Fatalf("正文应为 UTF-8 %s，得到 %s (%v)", wantType, mediaType, err)
				}
				bodyBytes, err := io.ReadAll(part)
				if err != nil {
					t.Fatal(err)
				}
				body := string(bodyBytes)
				for _, want := range []string{tc.title, "输入验证码，" + tc.action, code, "17 分钟内有效", "可忽略这封邮件"} {
					if !strings.Contains(body, want) {
						t.Errorf("%s 正文缺少 %q", wantType, want)
					}
				}
				if wantType == "text/html" && !strings.Contains(body, ">"+code+"</td>") {
					t.Error("HTML 正文应将完整验证码放在一个可复制的文本节点中")
				}
			}
			if _, err := parts.NextPart(); err != io.EOF {
				t.Fatalf("两份正文后应是邮件结尾，得到 %v", err)
			}
		})
	}
}

// TestParseRetryAfterHint 核对能从服务商的响应文本里读出建议等待秒数，读不出来
// 都返回零；超过上限时截到上限，交给调用方按上限放弃这次发送。
func TestParseRetryAfterHint(t *testing.T) {
	cases := []struct {
		in   error
		want time.Duration
	}{
		{errors.New("550 5.7.1 Retry-After: 12 please wait"), 12 * time.Second},
		{errors.New("retry-after=3"), 3 * time.Second},
		{errors.New("too many messages, Retry-After: 600"), 30 * time.Second},
		{errors.New("no hint here"), 0},
		{nil, 0},
	}
	for _, c := range cases {
		if got := ParseRetryAfterHint(c.in); got != c.want {
			t.Errorf("ParseRetryAfterHint(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

// TestIsTemporary 核对 4xx 与网络错误重试、5xx 与鉴权失败不重试。
func TestIsTemporary(t *testing.T) {
	if !isTemporary(&textproto.Error{Code: 451, Msg: "try later"}) {
		t.Error("451 应当重试")
	}
	if isTemporary(&textproto.Error{Code: 550, Msg: "rejected"}) {
		t.Error("550 不应重试")
	}
	if !isTemporary(io.ErrUnexpectedEOF) {
		t.Error("连接中途断开应当重试")
	}
	var netErr net.Error = &net.OpError{Op: "dial", Err: errors.New("timeout")}
	if !isTemporary(netErr) {
		t.Error("网络错误应当重试")
	}
}

// TestMailerRetriesTemporaryFailureThenPauses 核对临时失败按次数重试，连续失败
// 达到阈值之后熔断，暂停期间 Send 直接返回 ErrMailPaused，不再拨号。
func TestMailerRetriesTemporaryFailureThenPauses(t *testing.T) {
	// 指向一个立即拒绝连接的地址，让每次尝试都失败在网络层。
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()

	m := NewSMTPMailer(MailerConfig{Addr: addr, MaxAttempts: 1})
	ctx := context.Background()
	message := MailMessage{Subject: "s", Text: "b", HTML: "<p>b</p>"}
	for i := 0; i < mailBreakerThreshold; i++ {
		if err := m.Send(ctx, "a@example.com", message); err == nil {
			t.Fatal("到已关闭的端口发信应当失败")
		}
	}
	if left := m.PausedFor(); left <= 0 {
		t.Fatalf("连续失败后应进入暂停，得到 %v", left)
	}
	if err := m.Send(ctx, "a@example.com", message); !errors.Is(err, ErrMailPaused) {
		t.Fatalf("暂停期间应返回 ErrMailPaused，得到 %v", err)
	}
}
