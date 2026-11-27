package server

import (
	"bytes"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/iotest"

	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

func TestBuildRejectsInvalidStartupConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*testing.T, *config.Config, llmproxy.Catalog)
		want   string
	}{
		{"invalid SMTP", func(_ *testing.T, c *config.Config, _ llmproxy.Catalog) { c.SMTPAddr = "smtp.example.test" }, "ZHIXIN_SMTP_ADDR"},
		{"missing SMTP", func(_ *testing.T, c *config.Config, _ llmproxy.Catalog) { c.SMTPAddr = "" }, "ZHIXIN_SMTP_ADDR"},
		{"bad encryption key", func(_ *testing.T, c *config.Config, _ llmproxy.Catalog) { c.SecretKey = []byte("short") }, "ZHIXIN_SECRET_KEY"},
		{"empty catalog", func(_ *testing.T, c *config.Config, _ llmproxy.Catalog) {
			c.AdminToken, c.DatabaseURL = "", "postgresql://test"
		}, "no usable model"},
		{"disabled model", func(t *testing.T, _ *config.Config, catalog llmproxy.Catalog) {
			if err := catalog.PutModel(t.Context(), llmproxy.ModelRecord{Name: "disabled", Enabled: false}); err != nil {
				t.Fatal(err)
			}
		}, "no usable model"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := startupTestConfig(t)
			stores := MemoryStores(cfg, slog.Default())
			tc.change(t, &cfg, stores.Catalog)
			handler, err := Build(t.Context(), cfg, stores, slog.Default())
			if handler != nil || err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Build() handler=%v, error=%v, want error containing %q", handler, err, tc.want)
			}
		})
	}
}

func TestStartupRejectsPartialRandomVerificationSecret(t *testing.T) {
	entropyErr := errors.New("entropy unavailable")
	random := io.MultiReader(strings.NewReader("partial"), iotest.ErrReader(entropyErr))
	cfg := startupTestConfig(t)
	cfg.CodeSecret = ""
	_, err := prepareStartup(t.Context(), cfg, llmproxy.NewMemoryCatalog(), slog.Default(), random, false)
	if !errors.Is(err, entropyErr) || !strings.Contains(err.Error(), "verification code secret") {
		t.Fatalf("prepareStartup() error=%v", err)
	}
}

func TestModelSetupRepairsCatalogBeforeServing(t *testing.T) {
	cfg := startupTestConfig(t)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	stores := MemoryStores(cfg, log)
	setup, err := BuildModelSetup(t.Context(), cfg, stores, log)
	if err != nil {
		t.Fatal(err)
	}
	request := func(method, path, token, body string, want int) {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		setup.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s %s: got %d, want %d (%s)", method, path, w.Code, want, w.Body)
		}
	}
	request("GET", "/admin/", "", "", http.StatusOK)
	request("GET", "/admin/v1/providers", "", "", http.StatusUnauthorized)
	request("POST", "/v1/auth/register", "", "{}", http.StatusNotFound)
	request("POST", "/admin/v1/providers", cfg.AdminToken,
		`{"id":"test","base_url":"https://model.example.test/v1","api_key":"fixture-key"}`, http.StatusCreated)
	request("POST", "/admin/v1/models", cfg.AdminToken,
		`{"name":"chat","kind":"chat","routes":[{"provider_id":"test","upstream_model":"chat"}]}`, http.StatusCreated)

	mustBuild(t, cfg, stores, log)
	// An unusable source must fail startup even if another route still works.
	if err := stores.Catalog.PutProvider(t.Context(), llmproxy.ProviderRecord{ID: "broken", APIKeySealed: "invalid-ciphertext"}); err != nil {
		t.Fatal(err)
	}
	if handler, err := Build(t.Context(), cfg, stores, log); handler != nil || err == nil || !strings.Contains(err.Error(), `source "broken" key cannot be decrypted`) {
		t.Fatalf("Build() with broken source handler=%v, error=%v", handler, err)
	}
	setup, err = BuildModelSetup(t.Context(), cfg, stores, log)
	if err != nil {
		t.Fatal(err)
	}
	request("DELETE", "/admin/v1/providers/broken", cfg.AdminToken, "", http.StatusNoContent)
	mustBuild(t, cfg, stores, log)
}

func startupTestConfig(t *testing.T) config.Config {
	t.Helper()
	cfg, err := config.Load(func(key string) string {
		return map[string]string{
			"ZHIXIN_ADMIN_TOKEN": testAdminToken,
			"ZHIXIN_SMTP_ADDR":   "smtp.example.test:587",
			"ZHIXIN_SMTP_FROM":   "test@example.test",
		}[key]
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg.SecretKey = bytes.Repeat([]byte{7}, 32)
	return cfg
}
