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
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
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
	// settlementFailures 是结算失败之后的补退入口，只有 PostgreSQL 实现；内存实现
	// 的结算不会失败，保持为空，补查循环直接返回（ADR-0086）。
	var settlementFailures llmproxy.SettlementFailureStore
	// nowpayClient 是购买接口的调用入口，与 meter 共用同一个客户端。
	var nowpayClient *nowpay.Client
	// nowpayMaintenance 是补查与保留期用的存储，配置了即刻收商品时才有值。
	var nowpayMaintenance nowpay.MaintenanceStore
	// chargePending 是结算之后还没有申请核销的用量，配置了即刻收商品时才有值。
	var chargePending nowpay.PendingChargeStore
	if cfg.DatabaseURL == "" {
		log.Warn("ZHIXIN_DATABASE_URL is empty: using in-memory stores, all data is lost on exit")
		stores = server.MemoryStores(cfg, log)
	} else {
		objects, err := openObjects(cfg, log)
		if err != nil {
			return err
		}
		pgStore, err := pg.Open(context.Background(), cfg.DatabaseURL, pg.Options{
			Objects: objects, Log: log,
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
		// 额度结算要有在途预留与嵌入计费两列，还要有结算失败的补偿表；缺任何一项
		// 都直接拒绝启动，让自动部署回滚到上一份文件（ADR-0071、ADR-0086）。
		checkCtx, checkCancel := context.WithTimeout(context.Background(), 8*time.Second)
		err = pgStore.CheckQuotaSchema(checkCtx)
		checkCancel()
		if err != nil {
			return err
		}
		settlementFailures = pgStore
		if cfg.NowPay != nil {
			nowpayClient, err = nowpay.NewClient(cfg.Alipay, cfg.NowPay.ProductID)
			if err != nil {
				return err
			}
		}
		stores, err = server.ProductionStores(context.Background(), cfg, pgStore, objects, nowpayClient, log)
		if err != nil {
			return err
		}
		if nowpayClient != nil {
			meter, err = nowpay.NewMeter(nowpayClient, pgStore, cfg.LLM.TokensPerPoint, log)
			if err != nil {
				return err
			}
			pgStore.SetNowPay(meter)
			nowpayMaintenance = pgStore
			chargePending = pgStore
			// 启动时查一次商品收费能力：配置错、商品未审核或应用凭证不匹配会在日志里
			// 先出现，购买接口的第一次请求不必承担这次排查；失败只记日志，不阻塞启动。
			probeCtx, probeCancel := context.WithTimeout(context.Background(), 5*time.Second)
			if _, err := nowpayClient.Charge(probeCtx); err != nil {
				log.Error("查询即刻收商品失败，购买入口会在请求时再试",
					"product_id", cfg.NowPay.ProductID, "error", err)
			}
			probeCancel()
		}
		log.Info("using PostgreSQL stores")
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
	// 全局补查每十分钟接手一次，保留期与对账日志每天一次，都在配置了即刻收商品时启用。
	// 这三个循环都是启动时先跑一次再进循环本身（见 periodic.Run），必须在 goroutine
	// 里启动，否则第一次补查会把主协程占住，Build 与 ListenAndServe 都走不到。
	if meter != nil {
		meter.Start(ctx)
		go nowpay.SweepLoop(ctx, meter, log)
		go nowpay.ChargeSweepLoop(ctx, chargePending, log)
		go nowpay.MaintenanceLoop(ctx, nowpayMaintenance, cfg.Location, cfg.LLM.TokensPerPoint, log)
	}
	// 结算失败留下的预留每十分钟补退一次、每天清一次两天之前的在途预留；它不依赖
	// 收款配置，配了数据库就启用（ADR-0086）。
	go llmproxy.SettlementSweepLoop(ctx, settlementFailures, log)

	handler := server.Build(ctx, cfg, stores, log)
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
