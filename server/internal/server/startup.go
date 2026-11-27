package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

type startupDependencies struct {
	mailer          auth.Mailer
	codeSecret      []byte
	telemetrySecret []byte
	box             *secretbox.Box
	router          *llmproxy.Router
}

func prepareStartup(ctx context.Context, cfg config.Config, catalog llmproxy.Catalog, log *slog.Logger, random io.Reader, setup bool) (startupDependencies, error) {
	strict := !setup && (cfg.AdminToken != "" || cfg.DatabaseURL != "" || cfg.NowPay != nil)
	mailer, err := auth.NewMailer(auth.MailerConfig{
		Addr:            cfg.SMTPAddr,
		From:            cfg.SMTPFrom,
		Username:        cfg.SMTPUsername,
		Password:        cfg.SMTPPassword,
		TLS:             cfg.SMTPTLS,
		LogOnly:         cfg.MailLog,
		MaxConcurrent:   cfg.SMTPMaxConcurrent,
		MaxAttempts:     cfg.SMTPMaxAttempts,
		RetryAfterError: auth.ParseRetryAfterHint,
	}, log)
	if err != nil {
		return startupDependencies{}, fmt.Errorf("invalid SMTP configuration: %w", err)
	}
	if strict && strings.TrimSpace(cfg.SMTPAddr) == "" {
		return startupDependencies{}, errors.New("ZHIXIN_SMTP_ADDR is required for serving with administration, PostgreSQL or NowPay")
	}
	codeSecret := []byte(cfg.CodeSecret)
	if len(codeSecret) == 0 {
		codeSecret = make([]byte, 32)
		if _, err := io.ReadFull(random, codeSecret); err != nil {
			return startupDependencies{}, fmt.Errorf("generate verification code secret: %w", err)
		}
		if !setup {
			log.Warn("ZHIXIN_CODE_SECRET is empty: verification codes stop working after a restart")
		}
	}
	telemetrySecret := []byte(cfg.TelemetrySecret)
	if len(telemetrySecret) == 0 {
		telemetrySecret = make([]byte, 32)
		if _, err := io.ReadFull(random, telemetrySecret); err != nil {
			return startupDependencies{}, fmt.Errorf("generate telemetry secret: %w", err)
		}
		if !setup {
			log.Warn("ZHIXIN_TELEMETRY_SECRET is empty: install hashes change on restart and active counts inflate")
		}
	}

	key := cfg.SecretKey
	if len(key) == 0 && cfg.DatabaseURL == "" {
		// An in-memory catalog and its encryption key share the process lifetime.
		key = make([]byte, 32)
		if _, err := io.ReadFull(random, key); err != nil {
			return startupDependencies{}, fmt.Errorf("generate model source encryption key: %w", err)
		}
	}
	var box *secretbox.Box
	if len(key) > 0 {
		box, err = secretbox.New(key)
		if err != nil {
			return startupDependencies{}, fmt.Errorf("ZHIXIN_SECRET_KEY is unusable: %w", err)
		}
	} else if cfg.AdminToken != "" {
		return startupDependencies{}, errors.New("ZHIXIN_SECRET_KEY is required for administration with PostgreSQL")
	}

	router := llmproxy.NewRouter(catalog, box, log)
	if err := router.Reload(ctx); err != nil {
		return startupDependencies{}, fmt.Errorf("load model catalog: %w", err)
	}
	if strict {
		if err := router.ValidateStartup(); err != nil {
			return startupDependencies{}, err
		}
	} else if !setup && router.ModelCount() == 0 {
		log.Warn("no model configured")
	}
	return startupDependencies{
		mailer:          mailer,
		codeSecret:      codeSecret,
		telemetrySecret: telemetrySecret,
		box:             box,
		router:          router,
	}, nil
}
