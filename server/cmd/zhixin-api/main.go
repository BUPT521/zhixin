// Command zhixin-api is the 知新 API backend. Configuration comes only from
// ZHIXIN_* environment variables; see server/README.md.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata" // the container image may not ship zoneinfo

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/server"
	"github.com/BUPT521/zhixin/server/internal/store"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("exit", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}

	var stores server.Stores
	if cfg.DatabaseURL == "" {
		log.Warn("ZHIXIN_DATABASE_URL is empty: using in-memory stores, all data is lost on exit")
		stores = server.MemoryStores()
	} else {
		if strings.TrimSpace(cfg.BackupDirectory) == "" {
			return errors.New("ZHIXIN_BACKUP_DIRECTORY is required with PostgreSQL")
		}
		objects, err := os.OpenRoot(cfg.BackupDirectory)
		if err != nil {
			return errors.New("could not open ZHIXIN_BACKUP_DIRECTORY")
		}
		defer objects.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
		if err != nil {
			cancel()
			return errors.New("invalid ZHIXIN_DATABASE_URL")
		}
		defer pool.Close()
		err = pool.Ping(ctx)
		cancel()
		if err != nil {
			var databaseError *pgconn.PgError
			if errors.As(err, &databaseError) {
				return errors.New("PostgreSQL refused to connect (SQLSTATE " + databaseError.Code + ")")
			}
			return errors.New("could not connect to PostgreSQL")
		}
		stores = server.Stores{
			Auth: store.Accounts(pool), Sync: store.SyncLog(pool),
			Backups: store.Backups(pool, objects), Quota: store.Quota(pool),
			Ready: pool.Ping,
		}
	}
	if cfg.LLM.APIKey == "" {
		log.Warn("ZHIXIN_LLM_API_KEY is empty: the model proxy answers 503")
	}

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           server.New(cfg, stores, log),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout: model streams and backup downloads can run for
		// minutes. Idle connections are still reaped.
		IdleTimeout: 120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errc := make(chan error, 1)
	go func() {
		log.Info("listening", slog.String("addr", cfg.Addr))
		errc <- srv.ListenAndServe()
	}()

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return err
	}
	if err := <-errc; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
