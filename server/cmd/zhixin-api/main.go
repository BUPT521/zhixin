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
	"github.com/BUPT521/zhixin/server/internal/nowpay"
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
	// meter 是即刻收的积分核销执行器；没有配置商品时保持为空，结算之后不产生核销。
	var meter *nowpay.Meter
	// nowpayClient 是购买接口的调用入口，与 meter 共用同一个客户端。
	var nowpayClient *nowpay.Client
	if cfg.DatabaseURL == "" {
		log.Warn("ZHIXIN_DATABASE_URL is empty: using in-memory stores, all data is lost on exit")
		stores = server.MemoryStores()
	} else {
		objects, err := openObjects(cfg, log)
		if err != nil {
			return err
		}
		pgStore, err := pg.Open(context.Background(), cfg.DatabaseURL, pg.Options{
			Objects: objects, PurchasedQuotaEnabled: cfg.Alipay != nil,
			PurchasedQuotaSandbox: cfg.Alipay != nil && cfg.Alipay.Sandbox(),
			Log:                   log,
		})
		if err != nil {
			return err
		}
		defer pgStore.Close()
		if cfg.ApplySchema {
			if err := pgStore.ApplySchema(context.Background()); err != nil {
				return err
			}
		}
		if cfg.Alipay != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			err := pgStore.CheckPurchaseSchema(ctx)
			cancel()
			if err != nil {
				return err
			}
		}
		if cfg.NowPay != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			err := pgStore.CheckNowPaySchema(ctx)
			cancel()
			if err != nil {
				return err
			}
			client, err := nowpay.NewClient(cfg.Alipay, cfg.NowPay.ProductID)
			if err != nil {
				return err
			}
			meter, err = nowpay.NewMeter(client, pgStore, cfg.NowPay.TokensPerPoint, log)
			if err != nil {
				return err
			}
			pgStore.SetNowPay(meter)
			nowpayClient = client
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
			Usage:     pgStore,
			Catalog:   pgStore,
			Cache:     pg.NewEmbeddingCache(pgStore),
			Feedback:  pgStore,
			Retention: pgStore,
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
		if cfg.Alipay != nil {
			stores.Payments = pgStore
		}
		// 即刻收的购买入口、流水与调用入口在整体装配之后补上：这里的赋值必须在
		// stores 赋值之后，否则会被上面那份字面量覆盖掉。
		if cfg.NowPay != nil {
			stores.Purchases = pgStore
			stores.NowPay = nowpayClient
		}
	}
	if cfg.AdminToken == "" {
		log.Info("ZHIXIN_ADMIN_TOKEN is empty: the admin page and /admin/v1 answer 404")
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
	// 核销协程跟着进程退出；队列里没有来得及处理的流水留在库里，下一轮请求前补查。
	if meter != nil {
		meter.Start(ctx)
	}

	handler, _ := server.Build(ctx, cfg, stores, log)
	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           handler,
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
