// Package config reads the server configuration from environment variables.
//
// Every secret (database password, upstream model key) arrives through the
// environment; nothing is read from files in the repository. The one exception
// is the release manifest: its path comes from ZHIXIN_RELEASE_FILE and the file
// itself lives outside the repository. See ADR-0009 and ADR-0025.
package config

import (
	"errors"
	"fmt"
	"net/mail"
	"strconv"
	"strings"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/release"
)

// Config is the complete runtime configuration of zhixin-api.
type Config struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// DatabaseURL is the PostgreSQL DSN. Empty means the in-memory store,
	// which is only for local development and tests.
	DatabaseURL string
	// Location decides where a "day" starts for the model quota.
	Location *time.Location

	AccessTTL  time.Duration
	RefreshTTL time.Duration

	// MaxJSONBytes caps ordinary JSON request bodies.
	MaxJSONBytes int64
	// MaxBackupBytes caps a single uploaded backup snapshot.
	MaxBackupBytes int64
	// MaxAttachmentBytes caps one uploaded attachment object.
	MaxAttachmentBytes int64
	// BackupsKept is how many snapshots are retained per account.
	BackupsKept int
	// BlobDir is the local directory for backup and attachment bytes. Used
	// when S3 is not configured.
	BlobDir string
	// S3 configures S3-compatible object storage; an empty endpoint means the
	// local directory is used instead (ADR-0016).
	S3 objectstore.S3Config
	// ApplySchema runs schema.sql on startup; meant for a fresh database.
	ApplySchema bool

	// AuthRatePerSecond 与 AuthBurst 是登录、注册按来源地址的令牌桶参数；
	// RefreshRatePerSecond 与 RefreshBurst 是刷新令牌按账号与地址的参数。
	// 设 AuthRatePerSecond 为 0 关闭限流（本地联调与测试用）。
	AuthRatePerSecond    float64
	AuthBurst            int
	RefreshRatePerSecond float64
	RefreshBurst         int

	// UploadRatePerSecond 与 UploadBurst 限制备份与附件上传按账号的速率；
	// 这两类请求会先落临时文件，设 0 关闭。
	UploadRatePerSecond float64
	UploadBurst         int

	// 邮箱验证与找回密码的发信。SMTPAddr 为空时这些接口返回 503；MailLog
	// 只在本机联调时把邮件写进日志，生产不能打开。
	SMTPAddr     string
	SMTPFrom     string
	SMTPUsername string
	SMTPPassword string
	SMTPTLS      string
	MailLog      bool
	// CodeSecret 是验证码 HMAC 的密钥；为空时每次启动随机生成，旧验证码随
	// 重启失效。生产应固定一个随机值，才不会因为重启让用户重发。
	CodeSecret string
	CodeTTL    time.Duration
	// CodeCooldown 是同一账号两次发送验证码的最小间隔。
	CodeCooldown time.Duration
	// CodeRatePerSecond 与 CodeBurst 限制发送验证码与重设密码的尝试，按账号
	// 或来源地址计；设 0 关闭。
	CodeRatePerSecond float64
	CodeBurst         int

	// FeedbackRatePerSecond 与 FeedbackBurst 限制应用内反馈的提交，按来源地址
	// 计；设 0 关闭。
	FeedbackRatePerSecond float64
	FeedbackBurst         int
	// TelemetrySecret 是匿名安装标识的 HMAC 密钥（ADR-0019）；为空时每次启动
	// 随机生成，重启后同一个安装会被当成新的，留存数字偏高。
	TelemetrySecret string
	// TelemetryRatePerSecond 与 TelemetryBurst 限制匿名活跃上报，按来源地址计；
	// 设 0 关闭。
	TelemetryRatePerSecond float64
	TelemetryBurst         int
	// TrustedProxy 为真时按 X-Forwarded-For 的最后一项取来源地址，用于直接
	// 对端是项目组反向代理的部署；对外直接暴露时必须保持关闭。
	TrustedProxy bool

	// ReleaseFile 是发布清单文件；为空表示还没有对外发布过安装包，更新检查
	// 返回空数组。
	ReleaseFile string
	// Releases 是启动时从 ReleaseFile 读入并校验过的清单，见 release.Load。
	Releases []release.Entry

	LLM LLMConfig
}

// LLMConfig configures the model proxy.
type LLMConfig struct {
	// BaseURL is the upstream OpenAI-compatible base, e.g. https://api.deepseek.com/v1.
	BaseURL string
	// APIKey is the provider key held by the server. Empty disables the proxy.
	APIKey string
	// Models is the allow-list of model names clients may request.
	Models []string
	// DailyTokens is the per-account daily token budget. The real number is
	// still to be decided (ADR-0008); this is only a configurable default.
	DailyTokens int64
	// MaxRequestBytes caps a proxied request body (images are inlined as base64).
	MaxRequestBytes int64
}

// Load builds a Config from getenv (normally os.Getenv).
func Load(getenv func(string) string) (Config, error) {
	var errs []error
	get := func(key, def string) string {
		if v := strings.TrimSpace(getenv(key)); v != "" {
			return v
		}
		return def
	}
	fnum := func(key, def string) float64 {
		v := get(key, def)
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 {
			errs = append(errs, fmt.Errorf("%s: want a non-negative number such as 0.2", key))
			return 0
		}
		return f
	}
	dur := func(key, def string) time.Duration {
		d, err := time.ParseDuration(get(key, def))
		if err != nil || d <= 0 {
			errs = append(errs, fmt.Errorf("%s: want a positive duration such as 1h", key))
		}
		return d
	}
	num := func(key, def string) int64 {
		n, err := strconv.ParseInt(get(key, def), 10, 64)
		if err != nil || n <= 0 {
			errs = append(errs, fmt.Errorf("%s: want a positive integer", key))
		}
		return n
	}

	loc, err := time.LoadLocation(get("ZHIXIN_TIMEZONE", "Asia/Shanghai"))
	if err != nil {
		errs = append(errs, fmt.Errorf("ZHIXIN_TIMEZONE: %w", err))
	}

	var models []string
	for _, m := range strings.Split(get("ZHIXIN_LLM_MODELS", "deepseek-flash"), ",") {
		if m = strings.TrimSpace(m); m != "" {
			models = append(models, m)
		}
	}

	cfg := Config{
		Addr:               get("ZHIXIN_ADDR", ":8080"),
		DatabaseURL:        get("ZHIXIN_DATABASE_URL", ""),
		Location:           loc,
		AccessTTL:          dur("ZHIXIN_ACCESS_TTL", "1h"),
		RefreshTTL:         dur("ZHIXIN_REFRESH_TTL", "720h"),
		MaxJSONBytes:       num("ZHIXIN_MAX_JSON_BYTES", "1048576"),
		MaxBackupBytes:     num("ZHIXIN_MAX_BACKUP_BYTES", "268435456"),
		MaxAttachmentBytes: num("ZHIXIN_MAX_ATTACHMENT_BYTES", "33554432"),
		BackupsKept:        int(num("ZHIXIN_BACKUPS_KEPT", "5")),
		BlobDir:            get("ZHIXIN_BLOB_DIR", "data/blobs"),
		ApplySchema:        get("ZHIXIN_APPLY_SCHEMA", "0") == "1",
		S3: objectstore.S3Config{
			Endpoint:  get("ZHIXIN_S3_ENDPOINT", ""),
			Bucket:    get("ZHIXIN_S3_BUCKET", "zhixin"),
			AccessKey: get("ZHIXIN_S3_ACCESS_KEY", ""),
			SecretKey: get("ZHIXIN_S3_SECRET_KEY", ""),
			Region:    get("ZHIXIN_S3_REGION", ""),
			UseSSL:    get("ZHIXIN_S3_USE_SSL", "0") == "1",
		},

		AuthRatePerSecond:    fnum("ZHIXIN_AUTH_RATE", "0.2"),
		AuthBurst:            int(num("ZHIXIN_AUTH_BURST", "10")),
		RefreshRatePerSecond: fnum("ZHIXIN_REFRESH_RATE", "1"),
		RefreshBurst:         int(num("ZHIXIN_REFRESH_BURST", "30")),
		UploadRatePerSecond:  fnum("ZHIXIN_UPLOAD_RATE", "0.5"),
		UploadBurst:          int(num("ZHIXIN_UPLOAD_BURST", "5")),

		SMTPAddr:          get("ZHIXIN_SMTP_ADDR", ""),
		SMTPFrom:          get("ZHIXIN_SMTP_FROM", ""),
		SMTPUsername:      get("ZHIXIN_SMTP_USERNAME", ""),
		SMTPPassword:      get("ZHIXIN_SMTP_PASSWORD", ""),
		SMTPTLS:           get("ZHIXIN_SMTP_TLS", "starttls"),
		MailLog:           get("ZHIXIN_MAIL_LOG", "0") == "1",
		CodeSecret:        get("ZHIXIN_CODE_SECRET", ""),
		CodeTTL:           dur("ZHIXIN_CODE_TTL", "10m"),
		CodeCooldown:      dur("ZHIXIN_CODE_COOLDOWN", "60s"),
		CodeRatePerSecond: fnum("ZHIXIN_CODE_RATE", "0.02"),
		CodeBurst:         int(num("ZHIXIN_CODE_BURST", "1")),

		FeedbackRatePerSecond: fnum("ZHIXIN_FEEDBACK_RATE", "0.02"),
		FeedbackBurst:         int(num("ZHIXIN_FEEDBACK_BURST", "3")),

		TelemetrySecret:        get("ZHIXIN_TELEMETRY_SECRET", ""),
		TelemetryRatePerSecond: fnum("ZHIXIN_TELEMETRY_RATE", "0.2"),
		TelemetryBurst:         int(num("ZHIXIN_TELEMETRY_BURST", "20")),

		TrustedProxy: get("ZHIXIN_TRUSTED_PROXY", "0") == "1",

		ReleaseFile: get("ZHIXIN_RELEASE_FILE", ""),

		LLM: LLMConfig{
			BaseURL:         strings.TrimRight(get("ZHIXIN_LLM_BASE_URL", "https://api.deepseek.com/v1"), "/"),
			APIKey:          get("ZHIXIN_LLM_API_KEY", ""),
			Models:          models,
			DailyTokens:     num("ZHIXIN_LLM_DAILY_TOKENS", "200000"),
			MaxRequestBytes: num("ZHIXIN_LLM_MAX_REQUEST_BYTES", "8388608"),
		},
	}
	if cfg.S3.Configured() {
		if cfg.S3.AccessKey == "" || cfg.S3.SecretKey == "" {
			errs = append(errs, errors.New("ZHIXIN_S3_ACCESS_KEY and ZHIXIN_S3_SECRET_KEY are required when ZHIXIN_S3_ENDPOINT is set"))
		}
		if strings.Contains(cfg.S3.Endpoint, "://") {
			errs = append(errs, errors.New("ZHIXIN_S3_ENDPOINT: give host and port only; use ZHIXIN_S3_USE_SSL to pick https"))
		}
	}
	if cfg.SMTPAddr != "" {
		if cfg.SMTPFrom == "" {
			errs = append(errs, errors.New("ZHIXIN_SMTP_FROM is required when ZHIXIN_SMTP_ADDR is set"))
		} else if _, err := mail.ParseAddress(cfg.SMTPFrom); err != nil {
			errs = append(errs, fmt.Errorf("ZHIXIN_SMTP_FROM: %w", err))
		}
		switch cfg.SMTPTLS {
		case "starttls", "implicit", "none":
		default:
			errs = append(errs, fmt.Errorf("ZHIXIN_SMTP_TLS: want starttls, implicit or none, got %q", cfg.SMTPTLS))
		}
		if cfg.SMTPUsername != "" && cfg.SMTPPassword == "" {
			errs = append(errs, errors.New("ZHIXIN_SMTP_PASSWORD is required when ZHIXIN_SMTP_USERNAME is set"))
		}
	}
	if cfg.AccessTTL >= cfg.RefreshTTL && len(errs) == 0 {
		errs = append(errs, errors.New("ZHIXIN_ACCESS_TTL must be shorter than ZHIXIN_REFRESH_TTL"))
	}
	// 发布清单不合法时启动直接失败：更新检查是公测前必须可用的功能，清单写错
	// 却照常启动，客户端只会一直拿到空清单。
	releases, err := release.Load(cfg.ReleaseFile)
	if err != nil {
		errs = append(errs, err)
	}
	cfg.Releases = releases
	return cfg, errors.Join(errs...)
}
