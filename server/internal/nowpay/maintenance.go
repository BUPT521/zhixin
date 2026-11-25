package nowpay

import (
	"context"
	"log/slog"
	"time"

	"github.com/BUPT521/zhixin/server/internal/periodic"
)

// MaintenanceStore 是补查与保留期需要的存储，由 store/pg 实现。补查走核销流水，
// 保留期删购买入口与终态流水，对账日志读流水状态计数与实例账本。
type MaintenanceStore interface {
	// UnsettledGlobal 取全局创建早于 before、仍未终结的流水。
	UnsettledGlobal(ctx context.Context, before time.Time, limit int) ([]Charge, error)
	// DeleteExpiredPurchases 分批删除有效期早于 before 的购买入口，返回删除行数。
	DeleteExpiredPurchases(ctx context.Context, before time.Time, limit int) (int64, error)
	// DeleteTerminalCharges 分批删除终态且更新时间早于 before 的流水，返回删除行数。
	DeleteTerminalCharges(ctx context.Context, before time.Time, limit int) (int64, error)
	// ChargeStatusCounts 返回核销流水按状态的计数。
	ChargeStatusCounts(ctx context.Context) (map[string]int64, error)
	// InstanceUsed 返回实例账本当天的用量。
	InstanceUsed(ctx context.Context, day string) (int64, error)
}

// 补查与保留期的参数。补查的间隔与宽限期按“核销最多晚一轮”估计；保留期按运维手册
// 的约定，购买入口留 30 天、终态流水留 180 天，批次固定 1000 行。
const (
	sweepInterval    = 10 * time.Minute
	sweepGrace       = 5 * time.Minute
	sweepBatch       = 50
	purchaseKeepDays = 30
	chargeKeepDays   = 180
	retentionBatch   = 1000
	maintenanceLimit = 5 * time.Minute
)

// SweepLoop 每十分钟把创建超过五分钟、仍然没有终结的流水排进核销队列。它兜住队列
// 满、进程重启与补查遗漏：核销失败不回滚已经交付的回答，流水只能靠补查收尾。
// 失败只记日志，下一轮再试。
//
// 函数会先就地跑一次再进循环，一直阻塞到 ctx 结束，调用方要用 goroutine 启动它。
func SweepLoop(ctx context.Context, meter *Meter, log *slog.Logger) {
	if meter == nil {
		return
	}
	periodic.Run(ctx, sweepInterval, func() {
		sweepCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		count, err := meter.Sweep(sweepCtx, time.Now().Add(-sweepGrace), sweepBatch)
		if err != nil {
			log.Error("sweep unsettled nowpay charges", "error", err)
			return
		}
		if count > 0 {
			log.Info("enqueued unsettled nowpay charges", "charges", count)
		}
	})
}

// Sweep 把一批超过宽限期仍未终结的流水排进核销队列，返回实际入队的条数。pending 的
// 用原参数重试核销，processing 的只查结果，与 Resume 的口径一致。
func (m *Meter) Sweep(ctx context.Context, olderThan time.Time, limit int) (int, error) {
	charges, err := m.ledger.UnsettledGlobal(ctx, olderThan, limit)
	if err != nil {
		return 0, err
	}
	enqueued := 0
	for _, charge := range charges {
		if m.enqueue(job{charge: charge, verify: charge.Status == StatusPending}) {
			enqueued++
		}
	}
	return enqueued, nil
}

// MaintenanceLoop 每天记一次对账日志，并按保留期分批删除过期购买入口与终态流水。
// 启动时先跑一次，之后每天一次；任何一步失败只记日志，不影响服务。与 SweepLoop
// 一样会阻塞到 ctx 结束，调用方要用 goroutine 启动它。
func MaintenanceLoop(ctx context.Context, store MaintenanceStore, log *slog.Logger) {
	if store == nil {
		return
	}
	periodic.Run(ctx, 24*time.Hour, func() {
		runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), maintenanceLimit)
		defer cancel()
		reconcile(runCtx, store, log)
		prune(runCtx, store, log)
	})
}

// reconcile 记一条按日对账日志：核销流水按状态计数与实例账本当天的用量。它不修数据，
// 只让积压、漏扣与实例账偏离在日志里看得见。
func reconcile(ctx context.Context, store MaintenanceStore, log *slog.Logger) {
	counts, err := store.ChargeStatusCounts(ctx)
	if err != nil {
		log.Error("read the nowpay charge counts", "error", err)
		return
	}
	day := time.Now().In(ChinaTime()).Format("2006-01-02")
	instance, err := store.InstanceUsed(ctx, day)
	if err != nil {
		log.Error("read the instance tokens for the reconciliation", "day", day, "error", err)
		return
	}
	log.Info("nowpay daily reconciliation",
		"day", day,
		"pending", counts[StatusPending],
		"processing", counts[StatusProcessing],
		"succeeded", counts[StatusSucceeded],
		"failed", counts[StatusFailed],
		"instance_tokens", instance)
}

// prune 按保留期分批删除：购买入口按有效期过期 30 天，核销流水按终态更新时间 180 天。
// pending 与 processing 不删，它们还没有结论。
func prune(ctx context.Context, store MaintenanceStore, log *slog.Logger) {
	now := time.Now()
	purchases := deleteInBatches(ctx, log, "nowpay_purchase", func(batchCtx context.Context, limit int) (int64, error) {
		return store.DeleteExpiredPurchases(batchCtx, now.AddDate(0, 0, -purchaseKeepDays), limit)
	})
	charges := deleteInBatches(ctx, log, "nowpay_charge", func(batchCtx context.Context, limit int) (int64, error) {
		return store.DeleteTerminalCharges(batchCtx, now.AddDate(0, 0, -chargeKeepDays), limit)
	})
	log.Info("pruned the nowpay rows", "purchases", purchases, "charges", charges)
}

// deleteInBatches 一批删除 limit 行，删满一批就继续，直到某一批少于 limit 或出错。
func deleteInBatches(ctx context.Context, log *slog.Logger, table string, fn func(context.Context, int) (int64, error)) int64 {
	var total int64
	for {
		deleted, err := fn(ctx, retentionBatch)
		if err != nil {
			log.Error("prune the nowpay rows", "table", table, "error", err)
			return total
		}
		total += deleted
		if deleted < retentionBatch {
			return total
		}
	}
}
