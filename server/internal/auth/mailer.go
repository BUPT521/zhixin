package auth

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"strings"
	"time"
)

// Mailer 把一封纯文本邮件交给发信通道。验证码只出现在邮件正文里，不写日志、
// 不进数据库明文；测试注入一个进程内实现，生产用 SMTP。
type Mailer interface {
	Send(ctx context.Context, to, subject, body string) error
}

// MailerConfig 是 SMTP 发信的配置。TLS 取 starttls、implicit 或 none：
// 465 端口用 implicit，587 与 25 端口通常用 starttls，本机联调可以用 none。
type MailerConfig struct {
	Addr     string
	From     string
	Username string
	Password string
	TLS      string
	// LogOnly 在没有配置 SMTP 时把邮件写进日志，只用于本机联调。生产不能打开，
	// 因为日志里会出现验证码。
	LogOnly bool
}

// NewMailer 按配置选择实现。Addr 为空且 LogOnly 关闭时返回 nil，调用方据此让
// 邮箱验证与找回密码返回 ErrMailUnavailable。
func NewMailer(cfg MailerConfig, log *slog.Logger) (Mailer, error) {
	if strings.TrimSpace(cfg.Addr) == "" {
		if cfg.LogOnly {
			return &logMailer{log: log}, nil
		}
		return nil, nil
	}
	addr, err := mail.ParseAddress(strings.TrimSpace(cfg.From))
	if err != nil {
		return nil, fmt.Errorf("auth: 发信地址 %q 不能用: %w", cfg.From, err)
	}
	cfg.Addr = strings.TrimSpace(cfg.Addr)
	cfg.From = addr.Address
	cfg.Username = strings.TrimSpace(cfg.Username)
	switch cfg.TLS {
	case "", "starttls":
		cfg.TLS = "starttls"
	case "implicit", "none":
	default:
		return nil, fmt.Errorf("auth: 未知的发信 TLS 模式 %q", cfg.TLS)
	}
	if cfg.Username != "" && cfg.Password == "" {
		return nil, errors.New("auth: 配置了 SMTP 用户名就必须配置口令")
	}
	return &smtpMailer{cfg: cfg}, nil
}

type logMailer struct{ log *slog.Logger }

func (m *logMailer) Send(_ context.Context, to, subject, body string) error {
	m.log.Warn("mail is written to the log because SMTP is not configured; never use this in production",
		slog.String("to", to),
		slog.String("subject", subject),
		slog.String("body", body),
	)
	return nil
}

type smtpMailer struct{ cfg MailerConfig }

func (m *smtpMailer) Send(ctx context.Context, to, subject, body string) error {
	host, _, err := net.SplitHostPort(m.cfg.Addr)
	if err != nil {
		return fmt.Errorf("auth: SMTP 地址应为 host:port: %w", err)
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var conn net.Conn
	if m.cfg.TLS == "implicit" {
		conn, err = tls.DialWithDialer(dialer, "tcp", m.cfg.Addr, &tls.Config{
			ServerName: host,
			MinVersion: tls.VersionTLS12,
		})
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", m.cfg.Addr)
	}
	if err != nil {
		return fmt.Errorf("auth: 连接 SMTP 失败: %w", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))

	client, err := smtp.NewClient(conn, host)
	if err != nil {
		return fmt.Errorf("auth: SMTP 握手失败: %w", err)
	}
	defer client.Close()

	if m.cfg.TLS == "starttls" {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return errors.New("auth: SMTP 服务器不支持 STARTTLS，可改用 implicit 或 none")
		}
		if err := client.StartTLS(&tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("auth: STARTTLS 失败: %w", err)
		}
	}
	if m.cfg.Username != "" {
		if err := client.Auth(smtp.PlainAuth("", m.cfg.Username, m.cfg.Password, host)); err != nil {
			return fmt.Errorf("auth: SMTP 鉴权失败: %w", err)
		}
	}
	if err := client.Mail(m.cfg.From); err != nil {
		return fmt.Errorf("auth: SMTP 发件人被拒绝: %w", err)
	}
	if err := client.Rcpt(to); err != nil {
		return fmt.Errorf("auth: SMTP 收件人被拒绝: %w", err)
	}
	writer, err := client.Data()
	if err != nil {
		return fmt.Errorf("auth: SMTP 开始正文失败: %w", err)
	}
	if _, err := writer.Write([]byte(message(m.cfg.From, to, subject, body))); err != nil {
		return fmt.Errorf("auth: SMTP 写正文失败: %w", err)
	}
	if err := writer.Close(); err != nil {
		return fmt.Errorf("auth: SMTP 提交正文失败: %w", err)
	}
	return client.Quit()
}

func message(from, to, subject, body string) string {
	subject = mime.QEncoding.Encode("UTF-8", subject)
	body = strings.ReplaceAll(body, "\r\n", "\n")
	body = strings.ReplaceAll(body, "\n", "\r\n")
	return "From: " + from + "\r\n" +
		"To: " + to + "\r\n" +
		"Subject: " + subject + "\r\n" +
		"MIME-Version: 1.0\r\n" +
		"Content-Type: text/plain; charset=UTF-8\r\n" +
		"Content-Transfer-Encoding: 8bit\r\n" +
		"\r\n" + body
}
