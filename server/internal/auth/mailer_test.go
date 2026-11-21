package auth

import (
	"context"
	"errors"
	"io"
	"net"
	"net/textproto"
	"testing"
	"time"
)

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
	for i := 0; i < mailBreakerThreshold; i++ {
		if err := m.Send(ctx, "a@example.com", "s", "b"); err == nil {
			t.Fatal("到已关闭的端口发信应当失败")
		}
	}
	if left := m.PausedFor(); left <= 0 {
		t.Fatalf("连续失败后应进入暂停，得到 %v", left)
	}
	if err := m.Send(ctx, "a@example.com", "s", "b"); !errors.Is(err, ErrMailPaused) {
		t.Fatalf("暂停期间应返回 ErrMailPaused，得到 %v", err)
	}
}
