package llmproxy

import (
	"context"
	"log/slog"
	"time"

	"github.com/BUPT521/zhixin/server/internal/periodic"
)

// SettlementFailureStore 是结算失败之后的补退入口，由 PostgreSQL 存储实现。内存
// 实现的结算不会失败，不需要这个入口。
type SettlementFailureStore interface {
	// SweepSettlementFailures 补退全局创建早于 before 的一批预留，返回处理掉的条数。
	SweepSettlementFailures(ctx context.Context, before time.Time, maxRows int) (int, error)
	// ClearReservationsBefore 清掉 before 之前不可能再结算的在途预留，返回清掉的行数。
	ClearReservationsBefore(ctx context.Context, before time.Time) (int64, error)
}

// 补查的间隔、宽限期与每批条数。宽限期让刚刚失败、正在自己补退的那一笔先走完，
// 全局补查不跟它抢同一行。
const (
	settlementSweepInterval = 10 * time.Minute
	settlementSweepGrace    = time.Minute
	settlementSweepBatch    = 50
	// settlementStaleAfter 是清掉在途预留时留下的余量：一次请求活不过两天，两天
	// 之前的预留一定不会再被结算。
	settlementStaleAfter = 48 * time.Hour
)

// SettlementSweepLoop 每十分钟补退一批结算失败留下的预留，每天清一次两天之前的在
// 途预留。前者兜住不再发请求的账号与进程重启之后没人补退的记录，后者兜住进程在
// 结算之前退出、连失败记录都没写进去的预留（ADR-0086）。函数先就地跑一次再进
// 循环，一直阻塞到 ctx 结束，调用方要用 goroutine 启动它。
func SettlementSweepLoop(ctx context.Context, store SettlementFailureStore, log *slog.Logger) {
	if store == nil {
		return
	}
	// 两条周期不同，各用一个协程：合在一个 ticker 里要自己记上一次清理的时间。
	go settlementClearLoop(ctx, store, log)
	periodic.Run(ctx, settlementSweepInterval, func() {
		runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		count, err := store.SweepSettlementFailures(runCtx, time.Now().Add(-settlementSweepGrace), settlementSweepBatch)
		if err != nil {
			log.Error("sweep the failed llm settlements", "error", err)
			return
		}
		if count > 0 {
			log.Warn("released the failed llm settlements", "rows", count)
		}
	})
}

// settlementClearLoop 每天清一次两天之前的在途预留。它与补查分开跑，读的是
// llm_usage 的整张表，不需要每十分钟做一次。
func settlementClearLoop(ctx context.Context, store SettlementFailureStore, log *slog.Logger) {
	periodic.Run(ctx, 24*time.Hour, func() {
		runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Minute)
		defer cancel()
		cleared, err := store.ClearReservationsBefore(runCtx, time.Now().Add(-settlementStaleAfter))
		if err != nil {
			log.Error("clear the stale llm reservations", "error", err)
			return
		}
		if cleared > 0 {
			log.Warn("cleared the stale llm reservations", "rows", cleared)
		}
	})
}
