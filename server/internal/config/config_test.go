package config

import (
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
