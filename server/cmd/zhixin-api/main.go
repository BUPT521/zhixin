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
	"syscall"
	"time"
	_ "time/tzdata" // the container image may not ship zoneinfo

	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/server"
	"github.com/BUPT521/zhixin/server/internal/store/pg"
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
		objects, err := openObjects(cfg, log)
		if err != nil {
			return err
		}
		pgStore, err := pg.Open(context.Background(), cfg.DatabaseURL, pg.Options{Objects: objects})
		if err != nil {
			return err
		}
		defer pgStore.Close()
		if cfg.ApplySchema {
			if err := pgStore.ApplySchema(context.Background()); err != nil {
				return err
			}
		}
		log.Info("using PostgreSQL stores")
		// 附件索引与配额写在 attachment 表里，BlobStore 负责索引与字节两件事；
		// 备份与附件的字节仍共用同一份对象存储。
		blobStore := pg.NewBlobStore(pgStore)
		stores = server.Stores{
			Auth:      pgStore,
			Sync:      pgStore,
			Backups:   pgStore,
			Blobs:     blobStore,
			Quota:     pgStore,
			Feedback:  pgStore,
			Retention: pgStore,
			Cloud:     pgStore,
			Objects:   objects,
			// 账号行删除后其余表按外键级联；对象存储里的备份与附件字节没有外键，
			// 由这里按前缀清理。
			DeleteAccount: server.DeleteAccountData(
				pgStore.DeleteUserObjects,
				blobStore.DeleteUser,
			),
			Ready: func(ctx context.Context) error {
				if err := pgStore.Ping(ctx); err != nil {
					return err
				}
				return objects.Ping(ctx)
			},
		}
	}
	if cfg.LLM.APIKey == "" {
		log.Warn("ZHIXIN_LLM_API_KEY is empty: the model proxy answers 503")
	}
	if len(cfg.Releases) == 0 {
		log.Warn("ZHIXIN_RELEASE_FILE is empty or lists no release: the update check returns an empty list")
	} else {
		log.Info("loaded the release manifest", slog.Int("releases", len(cfg.Releases)))
	}

	// 清理循环（会话与验证码过期行、反馈保留期）随 ctx 一起停止，所以先建
	// 信号上下文，再构造处理器。
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           server.New(ctx, cfg, stores, log),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout: model streams and backup downloads can run for
		// minutes. Idle connections are still reaped.
		IdleTimeout: 120 * time.Second,
	}

	// 匿名活跃按保留期滚动删除：启动时清一次，之后每天一次，与进程重启无关。
	go retention.PruneLoop(ctx, stores.Retention, cfg.Location, log)

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

// openObjects 选择字节的存放位置：配置了 S3 兼容存储就用它，否则用
// ZHIXIN_BLOB_DIR 指定的本地目录，保证没有对象存储的开发环境也能跑。
func openObjects(cfg config.Config, log *slog.Logger) (objectstore.Store, error) {
	if cfg.S3.Configured() {
		objects, err := objectstore.NewS3(cfg.S3)
		if err != nil {
			return nil, err
		}
		log.Info("using S3-compatible object storage",
			slog.String("endpoint", cfg.S3.Endpoint), slog.String("bucket", cfg.S3.Bucket))
		return objects, nil
	}
	objects, err := objectstore.NewDir(cfg.BlobDir)
	if err != nil {
		return nil, err
	}
	log.Info("using a local directory for backup and attachment bytes", slog.String("blob_dir", cfg.BlobDir))
	return objects, nil
}
