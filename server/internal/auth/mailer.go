package auth

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net"
	"net/mail"
	"net/smtp"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
	"time"
)

// MailMessage 包含主题及同一封邮件的纯文本和 HTML 正文。
type MailMessage struct {
	Subject string
	Text    string
	HTML    string
}

// Mailer 把邮件交给发信通道。生产通过 SMTP 发送，本机联调可使用日志实现。
type Mailer interface {
	Send(ctx context.Context, to string, message MailMessage) error
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
	// MaxConcurrent 是同时占用的 SMTP 连接数上限，为零时默认 4。发信是同步的，
	// 每次新建一条连接，不设上限时一批请求会把处理协程全部占在拨号与等待上。
	MaxConcurrent int
	// MaxAttempts 是临时失败时的总尝试次数，为零时默认 3（最多重试两次）。
	MaxAttempts int
	// MaxRetryAfter 是一次发送愿意等待服务商限速的上限，为零时默认 30 秒。服务商
	// 给出的等待超过它时直接放弃这次发送，把验证码作废，让用户稍后重新申请，而不是
	// 把请求挂住几分钟。
	MaxRetryAfter time.Duration
	// RetryAfterError 返回服务商给出的建议等待时长，读不出来返回零。它由配置里
	// 的提示字符串转成，见 ParseRetryAfterHint。
	RetryAfterError func(error) time.Duration
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
	cfg.Addr = strings.TrimSpace(cfg.Addr)
	host, port, err := net.SplitHostPort(cfg.Addr)
	portNumber, portErr := strconv.ParseUint(port, 10, 16)
	if err != nil || host == "" || strings.ContainsAny(host, " /@\t\r\n") || portErr != nil || portNumber == 0 {
		return nil, errors.New("auth: ZHIXIN_SMTP_ADDR must be a host and numeric port")
	}
	addr, err := mail.ParseAddress(strings.TrimSpace(cfg.From))
	if err != nil {
		return nil, fmt.Errorf("auth: 发信地址 %q 不能用: %w", cfg.From, err)
	}
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
	return NewSMTPMailer(cfg), nil
}

type logMailer struct{ log *slog.Logger }

func (m *logMailer) Send(_ context.Context, to string, message MailMessage) error {
	m.log.Warn("mail is written to the log because SMTP is not configured; never use this in production",
		slog.String("to", to),
		slog.String("subject", message.Subject),
		slog.String("body", message.Text),
	)
	return nil
}

type smtpMailer struct {
	cfg MailerConfig
	// sem 限住同时在途的连接数；池满时 Send 排队，不直接拒绝。
	sem chan struct{}
	// mu 保存熔断状态：服务商连续回临时失败时整体暂停发信，
	// 失败次数归零后才恢复，避免每个请求都先付一次连接与超时。
	mu          sync.Mutex
	failures    int
	pausedUntil time.Time
}

// NewSMTPMailer 按配置建一个 SMTP 发信器。
//
// 并发数、尝试次数与等待上限的默认值只由配置层一处给出（
// ZHIXIN_SMTP_MAX_CONCURRENT=4、ZHIXIN_SMTP_MAX_ATTEMPTS=3、
// ZHIXIN_SMTP_MAX_RETRY_AFTER=30s），配置层的 num 与 dur 已拒绝非正值，生产路径
// 不会命中的补零只服务直接构造 MailerConfig 的测试，改默认值请改 config.go。
func NewSMTPMailer(cfg MailerConfig) *smtpMailer {
	if cfg.MaxConcurrent <= 0 {
		cfg.MaxConcurrent = 4
	}
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 3
	}
	if cfg.MaxRetryAfter <= 0 {
		cfg.MaxRetryAfter = defaultMailMaxRetryAfter
	}
	return &smtpMailer{cfg: cfg, sem: make(chan struct{}, cfg.MaxConcurrent)}
}

// 熔断的阈值：连续失败达到 3 次后暂停，暂停时长从 30 秒起翻倍，最长 5 分钟。
const (
	mailBreakerThreshold = 3
	mailBreakerMinPause  = 30 * time.Second
	mailBreakerMaxPause  = 5 * time.Minute
)

// retryDelays 是临时失败后的重试间隔；它与服务商给出的 Retry-After 取较大者。
var retryDelays = []time.Duration{time.Second, 3 * time.Second}

// ParseRetryAfterHint 从 SMTP 的响应文本里读“稍后再试”的秒数，装配处把它交给
// MailerConfig.RetryAfterError。腾讯与企业邮箱这类服务商把限速写在响应文本里，
// 没有消息级头，只能按提示里的数字近似；读不出来返回零。
func ParseRetryAfterHint(err error) time.Duration {
	if err == nil {
		return 0
	}
	text := err.Error()
	idx := strings.Index(strings.ToLower(text), "retry-after")
	if idx < 0 {
		return 0
	}
	rest := text[idx+len("retry-after"):]
	rest = strings.TrimLeft(rest, " :=")
	digits := ""
	for _, r := range rest {
		if r < '0' || r > '9' {
			break
		}
		digits += string(r)
	}
	if digits == "" {
		return 0
	}
	var seconds int
	if _, err := fmt.Sscanf(digits, "%d", &seconds); err != nil || seconds <= 0 {
		return 0
	}
	// 这里只做防溢出的上限；一次发送愿意等多久由 MailerConfig.MaxRetryAfter 决定，
	// 超过它的等待在 send 里直接放弃，不在这里截断成一个看不出原因的值。
	if max := int(maxParseRetryAfter / time.Second); seconds > max {
		seconds = max
	}
	return time.Duration(seconds) * time.Second
}

// defaultMailMaxRetryAfter 是一次发送在没有配置时愿意为服务商限速等待的上限。
// 装配处用 ZHIXIN_SMTP_MAX_RETRY_AFTER 覆盖它。
const defaultMailMaxRetryAfter = 30 * time.Second

// maxParseRetryAfter 是解析服务商提示时的防溢出上限，远高于发送愿意等待的值。
const maxParseRetryAfter = 24 * time.Hour

// isTemporary 判断一次发信失败是否值得重试：连接、超时与 4xx 这类临时错误重试，
// 鉴权失败、收件人被拒与格式错误重试也只是再失败一次。请求取消不是服务商的临时
// 失败，用户关掉页面三次不能把整个实例的发信熔断掉。
func isTemporary(err error) bool {
	if err == nil || errors.Is(err, context.Canceled) {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	var smtpErr *textproto.Error
	if errors.As(err, &smtpErr) {
		return smtpErr.Code >= 400 && smtpErr.Code < 500
	}
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, context.DeadlineExceeded)
}

func (m *smtpMailer) Send(ctx context.Context, to string, message MailMessage) error {
	if pause := m.paused(); pause > 0 {
		return mailPauseError{retryAfter: max(1, int64(pause/time.Second))}
	}
	select {
	case m.sem <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	defer func() { <-m.sem }()
	data, err := encodeMail(m.cfg.From, to, message)
	if err != nil {
		return fmt.Errorf("auth: 编码邮件失败: %w", err)
	}
	return m.send(ctx, to, data)
}

func (m *smtpMailer) send(ctx context.Context, to string, data []byte) error {
	var lastErr error
	for attempt := 0; attempt < m.cfg.MaxAttempts; attempt++ {
		err := m.deliver(ctx, to, data)
		if err == nil {
			m.record(nil)
			return nil
		}
		lastErr = err
		// 请求已经取消时不再拨号，也不把这次失败记进熔断：用户关页面不是服务商
		// 的临时故障，连续几次取消不能暂停整个实例的发信。
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if errors.Is(err, context.Canceled) {
			return err
		}
		if !isTemporary(err) || attempt == m.cfg.MaxAttempts-1 {
			break
		}
		wait := retryDelays[min(attempt, len(retryDelays)-1)]
		if m.cfg.RetryAfterError != nil {
			if fromServer := m.cfg.RetryAfterError(err); fromServer > wait {
				wait = fromServer
			}
		}
		// 等待超过配置的上限时放弃这次发送；上限可配置，解析提示时不再把它截成
		// 一个永远到不了的值。
		if wait > m.cfg.MaxRetryAfter {
			break
		}
		timer := time.NewTimer(wait)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		}
	}
	m.record(lastErr)
	return lastErr
}

// PausedFor 报告熔断还要暂停多久，0 表示可以继续发信。
func (m *smtpMailer) PausedFor() time.Duration { return m.paused() }

func (m *smtpMailer) paused() time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.failures < mailBreakerThreshold {
		return 0
	}
	if left := time.Until(m.pausedUntil); left > 0 {
		return left
	}
	return 0
}

func (m *smtpMailer) record(err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err == nil {
		m.failures = 0
		m.pausedUntil = time.Time{}
		return
	}
	if !isTemporary(err) {
		return
	}
	m.failures++
	if m.failures < mailBreakerThreshold {
		return
	}
	pause := mailBreakerMinPause << (m.failures - mailBreakerThreshold)
	if pause > mailBreakerMaxPause || pause <= 0 {
		pause = mailBreakerMaxPause
	}
	m.pausedUntil = time.Now().Add(pause)
}

func (m *smtpMailer) deliver(ctx context.Context, to string, data []byte) error {
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
	if _, err := writer.Write(data); err != nil {
		return fmt.Errorf("auth: SMTP 写正文失败: %w", err)
	}
	if err := writer.Close(); err != nil {
		return fmt.Errorf("auth: SMTP 提交正文失败: %w", err)
	}
	return client.Quit()
}

func encodeMail(from, to string, message MailMessage) ([]byte, error) {
	var data bytes.Buffer
	parts := multipart.NewWriter(&data)
	fmt.Fprintf(&data, "From: %s\r\nTo: %s\r\nDate: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative;\r\n boundary=\"%s\"\r\n\r\n",
		from, to, time.Now().Format(time.RFC1123Z), mime.QEncoding.Encode("UTF-8", message.Subject), parts.Boundary())
	for _, part := range []struct{ mediaType, body string }{
		{"text/plain", message.Text},
		{"text/html", message.HTML},
	} {
		writer, err := parts.CreatePart(textproto.MIMEHeader{
			"Content-Type":              {part.mediaType + "; charset=UTF-8"},
			"Content-Transfer-Encoding": {"quoted-printable"},
		})
		if err != nil {
			return nil, err
		}
		encoded := quotedprintable.NewWriter(writer)
		if _, err := io.WriteString(encoded, part.body); err != nil {
			return nil, err
		}
		if err := encoded.Close(); err != nil {
			return nil, err
		}
	}
	if err := parts.Close(); err != nil {
		return nil, err
	}
	return data.Bytes(), nil
}
