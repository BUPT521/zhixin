package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// twoArgEnv 模拟 Load 里读配置的两参形式：键不存在时回落到默认值。
func twoArgEnv(m map[string]string) func(string, string) string {
	return func(k, fallback string) string {
		if value, ok := m[k]; ok {
			return value
		}
		return fallback
	}
}

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Addr != ":8080" || cfg.AccessTTL != time.Hour || cfg.RefreshTTL != 720*time.Hour {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	if cfg.LLM.DailyTokens != 320000 || cfg.LLM.MaxAttempts != 3 {
		t.Fatalf("unexpected llm defaults: %+v", cfg.LLM)
	}
}

func TestLoadRejectsBadValues(t *testing.T) {
	_, err := Load(env(map[string]string{
		"ZHIXIN_ACCESS_TTL":       "soon",
		"ZHIXIN_LLM_DAILY_TOKENS": "-1",
	}))
	if err == nil {
		t.Fatal("want error")
	}
	for _, key := range []string{"ZHIXIN_ACCESS_TTL", "ZHIXIN_LLM_DAILY_TOKENS"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error %q does not name %s", err, key)
		}
	}
}

func TestLoadRequiresAccessShorterThanRefresh(t *testing.T) {
	_, err := Load(env(map[string]string{"ZHIXIN_ACCESS_TTL": "800h"}))
	if err == nil {
		t.Fatal("want error")
	}
}

func TestLoadS3(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"ZHIXIN_S3_ENDPOINT":   "minio:9000",
		"ZHIXIN_S3_ACCESS_KEY": "ak",
		"ZHIXIN_S3_SECRET_KEY": "sk",
		"ZHIXIN_S3_USE_SSL":    "1",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.S3.Configured() || cfg.S3.Bucket != "zhixin" || !cfg.S3.UseSSL {
		t.Fatalf("s3 = %+v", cfg.S3)
	}
	if cfg.MaxAttachmentBytes != 33554432 {
		t.Fatalf("attachment limit = %d", cfg.MaxAttachmentBytes)
	}
}

func TestLoadS3RejectsPartialConfig(t *testing.T) {
	_, err := Load(env(map[string]string{
		"ZHIXIN_S3_ENDPOINT": "minio:9000",
	}))
	if err == nil || !strings.Contains(err.Error(), "ZHIXIN_S3_ACCESS_KEY") {
		t.Fatalf("want a missing credential error, got %v", err)
	}
	_, err = Load(env(map[string]string{
		"ZHIXIN_S3_ENDPOINT":   "https://minio:9000",
		"ZHIXIN_S3_ACCESS_KEY": "ak",
		"ZHIXIN_S3_SECRET_KEY": "sk",
	}))
	if err == nil || !strings.Contains(err.Error(), "ZHIXIN_S3_ENDPOINT") {
		t.Fatalf("want a scheme error, got %v", err)
	}
}

func TestLoadWithoutReleaseFile(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ReleaseFile != "" || len(cfg.Releases) != 0 {
		t.Fatalf("默认没有发布清单：%+v", cfg)
	}
	if cfg.FeedbackRatePerSecond <= 0 || cfg.FeedbackBurst < 1 {
		t.Fatalf("反馈默认应开启限流：%+v", cfg)
	}
	if len(cfg.TrustedProxies) != 0 {
		t.Fatal("没有配置反代时不应相信 X-Forwarded-For")
	}
}

// TestLoadDefaultsForHardening 守住本轮新增配置的默认值：改动默认值等于改动
// 线上行为，需要同时改 README 与 ADR-0028。
func TestLoadDefaultsForHardening(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.BodyIdleTimeout != 60*time.Second {
		t.Fatalf("body idle timeout = %v", cfg.BodyIdleTimeout)
	}
	if cfg.MaxSessionsPerUser != 20 {
		t.Fatalf("max sessions = %d", cfg.MaxSessionsPerUser)
	}
	if cfg.Argon2MemoryBudgetMiB != 256 {
		t.Fatalf("argon2 budget = %d", cfg.Argon2MemoryBudgetMiB)
	}
	if cfg.LoginFailRatePerSecond <= 0 || cfg.LoginFailBurst != 10 {
		t.Fatalf("login fail budget = %v/%d", cfg.LoginFailRatePerSecond, cfg.LoginFailBurst)
	}
	if cfg.RateLimitKeys != 100000 {
		t.Fatalf("rate limit keys = %d", cfg.RateLimitKeys)
	}
	if cfg.MaxAccountAttachmentBytes != 2<<30 {
		t.Fatalf("account attachment bytes = %d", cfg.MaxAccountAttachmentBytes)
	}
	if cfg.SyncPullMaxBytes != 4<<20 {
		t.Fatalf("sync pull bytes = %d", cfg.SyncPullMaxBytes)
	}
	if cfg.SyncCompact {
		t.Fatal("压缩默认应关闭")
	}
	if cfg.SyncSnapshotGrace != 24*time.Hour {
		t.Fatalf("快照回收宽限期默认 24 小时，得到 %v", cfg.SyncSnapshotGrace)
	}
	if cfg.SyncDeviceActive != 720*time.Hour {
		t.Fatalf("设备活跃窗口默认 720 小时，得到 %v", cfg.SyncDeviceActive)
	}
	if !cfg.LLM.RequireVerifiedContact || cfg.LLM.ConcurrentPerUser != 4 {
		t.Fatalf("llm gates = %+v", cfg.LLM)
	}
	if cfg.LLM.InstanceDailyTokens <= cfg.LLM.DailyTokens {
		t.Fatalf("实例总预算应大于单账号预算：%+v", cfg.LLM)
	}
	if cfg.LLM.MaxResponseBytes != 32<<20 {
		t.Fatalf("llm response bytes = %d", cfg.LLM.MaxResponseBytes)
	}
	if cfg.LLM.MaxInstanceBytes != 512<<20 {
		t.Fatalf("llm instance bytes = %d", cfg.LLM.MaxInstanceBytes)
	}
	if cfg.LLM.StreamIdleTimeout <= 0 || cfg.LLM.StreamTotalTimeout <= cfg.LLM.StreamIdleTimeout {
		t.Fatalf("llm stream timeouts = %+v", cfg.LLM)
	}
	if cfg.FeedbackKeepDays != 365 {
		t.Fatalf("feedback keep days = %d", cfg.FeedbackKeepDays)
	}
	if cfg.FeedbackGlobalRatePerSecond <= 0 || cfg.TelemetryGlobalRatePerSecond <= 0 {
		t.Fatal("反馈与匿名上报的全局写入上限默认应开启")
	}
	if cfg.RegisterGlobalRatePerSecond <= 0 || cfg.RegisterGlobalBurst != 10 {
		t.Fatalf("注册的全局上限默认应开启：%v/%d", cfg.RegisterGlobalRatePerSecond, cfg.RegisterGlobalBurst)
	}
	if cfg.UnverifiedKeepDays != 7 {
		t.Fatalf("未验证账号默认保留 7 天，得到 %d", cfg.UnverifiedKeepDays)
	}
	if cfg.BackupReconcileInterval != 24*time.Hour {
		t.Fatalf("对象存储对账默认每天一次，得到 %v", cfg.BackupReconcileInterval)
	}
}

func TestLoadSyncSnapshotOptions(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"ZHIXIN_SYNC_COMPACT":        "1",
		"ZHIXIN_SYNC_SNAPSHOT_GRACE": "48h",
		"ZHIXIN_SYNC_DEVICE_ACTIVE":  "24h",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.SyncCompact || cfg.SyncSnapshotGrace != 48*time.Hour || cfg.SyncDeviceActive != 24*time.Hour {
		t.Fatalf("快照回收与压缩门槛: compact=%v grace=%v active=%v", cfg.SyncCompact, cfg.SyncSnapshotGrace, cfg.SyncDeviceActive)
	}
	// 只写 0 或 1；其它值按关闭处理，避免把拼写错误当成打开。
	cfg, err = Load(env(map[string]string{"ZHIXIN_SYNC_COMPACT": "true"}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SyncCompact {
		t.Fatal("ZHIXIN_SYNC_COMPACT 只认 1")
	}
}

func TestLoadTrustedProxies(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"ZHIXIN_TRUSTED_PROXIES": "203.0.113.10, 10.0.0.0/8, 2001:db8::1/64",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.TrustedProxies) != 3 {
		t.Fatalf("proxies = %+v", cfg.TrustedProxies)
	}
	if got := cfg.TrustedProxies[0].String(); got != "203.0.113.10/32" {
		t.Fatalf("first = %q", got)
	}
	if got := cfg.TrustedProxies[2].String(); got != "2001:db8::/64" {
		t.Fatalf("third = %q", got)
	}

	for _, raw := range []string{"nope", "0.0.0.0/0", "::/0"} {
		if _, err := Load(env(map[string]string{"ZHIXIN_TRUSTED_PROXIES": raw})); err == nil {
			t.Fatalf("%q 应当被拒绝", raw)
		}
	}
}

// TestLoadProductionSelfCheck 守住生产配置自检：配置了数据库之后，验证码不能
// 写日志、两个密钥必须固定。
func TestLoadProductionSelfCheck(t *testing.T) {
	base := map[string]string{
		"ZHIXIN_DATABASE_URL":     "postgres://example/zhixin",
		"ZHIXIN_CODE_SECRET":      "code-secret",
		"ZHIXIN_TELEMETRY_SECRET": "telemetry-secret",
		"ZHIXIN_SMTP_ADDR":        "smtp.example.test:587",
		"ZHIXIN_SMTP_FROM":        "noreply@example.test",
		"ZHIXIN_SMTP_USERNAME":    "noreply",
		"ZHIXIN_SMTP_PASSWORD":    "pw",
		"ZHIXIN_SMTP_TLS":         "starttls",
	}
	if _, err := Load(env(base)); err != nil {
		t.Fatalf("合法生产配置不应报错：%v", err)
	}

	cases := []struct {
		name string
		key  string
		val  string
		want string
	}{
		{"验证码写日志", "ZHIXIN_MAIL_LOG", "1", "ZHIXIN_MAIL_LOG"},
		{"缺验证码密钥", "ZHIXIN_CODE_SECRET", "", "ZHIXIN_CODE_SECRET"},
		{"缺匿名统计密钥", "ZHIXIN_TELEMETRY_SECRET", "", "ZHIXIN_TELEMETRY_SECRET"},
		{"非回环 SMTP 不加密", "ZHIXIN_SMTP_TLS", "none", "ZHIXIN_SMTP_TLS"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := map[string]string{}
			for k, v := range base {
				m[k] = v
			}
			if tc.val == "" {
				delete(m, tc.key)
			} else {
				m[tc.key] = tc.val
			}
			_, err := Load(env(m))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want %s error, got %v", tc.want, err)
			}
		})
	}

	// 回环地址的 SMTP 在 none 模式下允许，供本机联调。
	loopback := map[string]string{
		"ZHIXIN_SMTP_ADDR":     "127.0.0.1:2525",
		"ZHIXIN_SMTP_FROM":     "noreply@example.test",
		"ZHIXIN_SMTP_USERNAME": "noreply",
		"ZHIXIN_SMTP_PASSWORD": "pw",
		"ZHIXIN_SMTP_TLS":      "none",
	}
	if _, err := Load(env(loopback)); err != nil {
		t.Fatalf("回环 SMTP 的明文联调应允许：%v", err)
	}
}

func TestLoadReadsReleaseManifest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "releases.json")
	body := `{"releases":[{"platform":"android","version":"0.2.0","build":2,"url":"https://example.test/a.apk","sha256":"0000000000000000000000000000000000000000000000000000000000000000","signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="}]}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	cfg, err := Load(env(map[string]string{"ZHIXIN_RELEASE_FILE": path}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.Releases) != 1 || cfg.Releases[0].Version != "0.2.0" {
		t.Fatalf("清单没有读入：%+v", cfg.Releases)
	}
}

func TestLoadRejectsBadReleaseManifest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "releases.json")
	if err := os.WriteFile(path, []byte(`{"releases":[{"platform":"android"}]}`), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, err := Load(env(map[string]string{"ZHIXIN_RELEASE_FILE": path}))
	if err == nil || !strings.Contains(err.Error(), "version") {
		t.Fatalf("清单不合法时启动应报错，得到 %v", err)
	}
}

func TestLoadModelRoutingDefaults(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.LLM.EmbeddingDailyTokens != 2000000 || cfg.LLM.EmbeddingMaxInputs != 256 || cfg.LLM.MaxAttempts != 3 || cfg.LLM.HeaderTimeout != time.Minute {
		t.Fatalf("unexpected routing defaults: %+v", cfg.LLM)
	}
	if cfg.AdminToken != "" || cfg.SecretKey != nil {
		t.Fatalf("后台默认关闭：%+v", cfg)
	}
}

func TestLoadAdminAndSecretKey(t *testing.T) {
	key := "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" // 32 字节
	long := strings.Repeat("a", 32)
	cases := []struct {
		name string
		env  map[string]string
		want string // 空表示应当通过
	}{
		{"short token", map[string]string{"ZHIXIN_ADMIN_TOKEN": "short"}, "ZHIXIN_ADMIN_TOKEN"},
		{"bad key", map[string]string{"ZHIXIN_SECRET_KEY": "c2hvcnQ="}, "ZHIXIN_SECRET_KEY"},
		{"db without key", map[string]string{"ZHIXIN_ADMIN_TOKEN": long, "ZHIXIN_DATABASE_URL": "postgres://x"}, "ZHIXIN_SECRET_KEY is required"},
		{"db with key", map[string]string{"ZHIXIN_ADMIN_TOKEN": long, "ZHIXIN_DATABASE_URL": "postgres://x", "ZHIXIN_SECRET_KEY": key}, ""},
		{"memory without key", map[string]string{"ZHIXIN_ADMIN_TOKEN": long}, ""},
	}
	for _, c := range cases {
		if c.env["ZHIXIN_DATABASE_URL"] != "" {
			c.env["ZHIXIN_CODE_SECRET"] = "code-secret"
			c.env["ZHIXIN_TELEMETRY_SECRET"] = "telemetry-secret"
		}
		cfg, err := Load(env(c.env))
		switch {
		case c.want == "" && err != nil:
			t.Fatalf("%s: %v", c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Fatalf("%s: want error containing %q, got %v", c.name, c.want, err)
		case c.name == "db with key" && len(cfg.SecretKey) != 32:
			t.Fatalf("%s: key not parsed", c.name)
		}
	}
}

// 即刻收的商品 ID 从「即刻收」小程序复制，形态固定；回调地址写错时启动就该拒绝，
// 而不是等到第一次购买才报错。
func TestParseNowPay(t *testing.T) {
	for _, c := range []struct {
		name string
		env  map[string]string
		want string // 期望的错误片段，空表示应当通过
	}{
		{"https callback", map[string]string{"ZHIXIN_NOWPAY_CALLBACK_URL": "https://app.example.com/nowpay/return"}, ""},
		{"http callback", map[string]string{"ZHIXIN_NOWPAY_CALLBACK_URL": "http://app.example.com/r"}, "CALLBACK_URL"},
		{"callback with fragment", map[string]string{"ZHIXIN_NOWPAY_CALLBACK_URL": "https://app.example.com/r#x"}, "CALLBACK_URL"},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, err := parseNowPay(twoArgEnv(c.env), "np_d_f83a7c91")
			switch {
			case c.want == "" && err != nil:
				t.Fatalf("want no error, got %v", err)
			case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
				t.Fatalf("want error containing %q, got %v", c.want, err)
			}
		})
	}
	if _, err := parseNowPay(twoArgEnv(nil), "not a product id"); err == nil {
		t.Fatal("商品 ID 带空格时应当拒绝")
	}
}

// 积分折算比例同时用于核销与前台展示，默认一千，写错时启动直接失败。
func TestLoadTokensPerPoint(t *testing.T) {
	cfg, err := Load(env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.LLM.TokensPerPoint != 1000 {
		t.Fatalf("默认比例应为 1000，得到 %d", cfg.LLM.TokensPerPoint)
	}
	cfg, err = Load(env(map[string]string{"ZHIXIN_TOKENS_PER_POINT": "500"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.LLM.TokensPerPoint != 500 {
		t.Fatalf("自定义比例应为 500，得到 %d", cfg.LLM.TokensPerPoint)
	}
	for _, raw := range []string{"0", "一千", "1000000001"} {
		if _, err := Load(env(map[string]string{"ZHIXIN_TOKENS_PER_POINT": raw})); err == nil ||
			!strings.Contains(err.Error(), "TOKENS_PER_POINT") {
			t.Fatalf("比例 %q 应当被拒绝，得到 %v", raw, err)
		}
	}
}
