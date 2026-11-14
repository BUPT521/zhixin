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
	// BackupsKept is how many snapshots are retained per account.
	BackupsKept int

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
		Addr:           get("ZHIXIN_ADDR", ":8080"),
		DatabaseURL:    get("ZHIXIN_DATABASE_URL", ""),
		Location:       loc,
		AccessTTL:      dur("ZHIXIN_ACCESS_TTL", "1h"),
		RefreshTTL:     dur("ZHIXIN_REFRESH_TTL", "720h"),
		MaxJSONBytes:   num("ZHIXIN_MAX_JSON_BYTES", "1048576"),
		MaxBackupBytes: num("ZHIXIN_MAX_BACKUP_BYTES", "268435456"),
		BackupsKept:    int(num("ZHIXIN_BACKUPS_KEPT", "5")),
		LLM: LLMConfig{
			BaseURL:         strings.TrimRight(get("ZHIXIN_LLM_BASE_URL", "https://api.deepseek.com/v1"), "/"),
			APIKey:          get("ZHIXIN_LLM_API_KEY", ""),
			Models:          models,
			DailyTokens:     num("ZHIXIN_LLM_DAILY_TOKENS", "200000"),
			MaxRequestBytes: num("ZHIXIN_LLM_MAX_REQUEST_BYTES", "8388608"),
		},
	}
	if cfg.AccessTTL >= cfg.RefreshTTL && len(errs) == 0 {
		errs = append(errs, errors.New("ZHIXIN_ACCESS_TTL must be shorter than ZHIXIN_REFRESH_TTL"))
	}
	return cfg, errors.Join(errs...)
}
