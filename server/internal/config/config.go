// Package config reads the server configuration from environment variables.
//
// Every secret (database password, upstream model key) arrives through the
// environment; nothing is read from files in the repository. See ADR-0009.
package config

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
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
	S3 S3Config
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

	LLM LLMConfig
}

// S3Config configures S3-compatible object storage. Endpoint is host[:port]
// without a scheme; the scheme follows UseSSL.
type S3Config struct {
	Endpoint  string
	Bucket    string
	AccessKey string
	SecretKey string
	Region    string
	UseSSL    bool
}

// Configured reports whether object storage is configured at all.
func (c S3Config) Configured() bool { return c.Endpoint != "" }

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
		S3: S3Config{
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
	if cfg.AccessTTL >= cfg.RefreshTTL && len(errs) == 0 {
		errs = append(errs, errors.New("ZHIXIN_ACCESS_TTL must be shorter than ZHIXIN_REFRESH_TTL"))
	}
	return cfg, errors.Join(errs...)
}
