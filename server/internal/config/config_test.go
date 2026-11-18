package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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
	if cfg.LLM.APIKey != "" {
		t.Fatal("proxy must be disabled unless a key is configured")
	}
	if got := strings.Join(cfg.LLM.Models, ","); got != "deepseek-flash" {
		t.Fatalf("models = %q", got)
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

func TestLoadTrimsModelList(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"ZHIXIN_LLM_MODELS":   " a , ,b ",
		"ZHIXIN_LLM_BASE_URL": "https://example.test/v1/",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cfg.LLM.Models, "|") != "a|b" || cfg.LLM.BaseURL != "https://example.test/v1" {
		t.Fatalf("got %+v", cfg.LLM)
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
	if cfg.TrustedProxy {
		t.Fatal("没有配置反代时不应相信 X-Forwarded-For")
	}
}

func TestLoadReadsReleaseManifest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "releases.json")
	body := `{"releases":[{"platform":"android","version":"0.2.0","build":2,"url":"https://example.test/a.apk"}]}`
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
	cfg, err := Load(env(map[string]string{"ZHIXIN_LLM_EMBEDDING_MODELS": " bge-m3 , ,text-embedding-v4"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := strings.Join(cfg.LLM.EmbeddingModels, ","); got != "bge-m3,text-embedding-v4" {
		t.Fatalf("embedding models = %q", got)
	}
	if cfg.LLM.EmbeddingDailyTokens != 2000000 || cfg.LLM.EmbeddingMaxInputs != 256 || cfg.LLM.MaxAttempts != 3 || cfg.LLM.HeaderTimeout != time.Minute {
		t.Fatalf("unexpected routing defaults: %+v", cfg.LLM)
	}
	if cfg.AdminToken != "" || cfg.SecretKey != nil || cfg.ModelReloadInterval != 30*time.Second {
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
