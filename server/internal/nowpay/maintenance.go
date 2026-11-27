package nowpay

import (
	"context"
	"log/slog"
	"time"

	"github.com/BUPT521/zhixin/server/internal/payment"
	"github.com/BUPT521/zhixin/server/internal/periodic"
)

// MaintenanceStore 是补查与保留期需要的存储，由 store/pg 实现。补查走核销流水，
// 保留期删购买入口与终态流水，对账读取账号用量、核销流水与实例账本。
type MaintenanceStore interface {
	// UnsettledGlobal 取全局创建早于 before、仍未终结的流水。
	UnsettledGlobal(ctx context.Context, before time.Time, limit int) ([]Charge, error)
	// DeleteExpiredPurchases 分批删除有效期早于 before 的购买入口，返回删除行数。
	DeleteExpiredPurchases(ctx context.Context, before time.Time, limit int) (int64, error)
	// DeleteTerminalCharges 分批删除终态且更新时间早于 before 的流水，返回删除行数。
	DeleteTerminalCharges(ctx context.Context, before time.Time, limit int) (int64, error)
	// DeleteOrphanCharges 分批删除删号之后失去归属、仍然没有结论的流水，返回删除行数。
	DeleteOrphanCharges(ctx context.Context, before time.Time, limit int) (int64, error)
	// ChargeStatusCounts 返回核销流水按状态的计数。
	ChargeStatusCounts(ctx context.Context) (map[string]int64, error)
	// InstanceUsed 返回实例账本当天的用量。
	InstanceUsed(ctx context.Context, day string) (int64, error)
	// DailyChargeReconciliation 返回指定记账日各账号的应核销计费量及流水汇总。
	DailyChargeReconciliation(ctx context.Context, day string) ([]AccountCharges, error)
}

type AccountCharges struct {
	UserID           string
	ChargeableTokens int64
	Applied          int64
	Charged          int64
}

// 补查与保留期的参数。这几项是代码常量，不是环境变量：补查的间隔与宽限期按
// “核销最多晚一轮”估计，保留期按运维手册 4.3 的约定，购买入口留 30 天、终态
// 流水留 180 天，批次固定 1000 行。调整它们要改代码并重新部署，运维手册已写明
// 这一口径。
const (
	sweepInterval = 10 * time.Minute
	sweepGrace    = 5 * time.Minute
	sweepBatch    = 50
	// maxSettleAttempts 是全局补查对同一笔流水的尝试上限。补查每十分钟一轮，每轮每笔
	// 最多记一次，一百次至少是十六个多小时；积压越大轮转越慢，实际时间更长。超过之后
	// 落成 abandoned，不再重试，也不再占住这一批的位置（ADR-0089）。
	maxSettleAttempts = 100
	purchaseKeepDays  = 30
	chargeKeepDays    = 180
	retentionBatch    = 1000
	maintenanceLimit  = 5 * time.Minute
)

// PendingChargeStore 是结算之后还没有申请核销的用量，由 store/pg 实现。
type PendingChargeStore interface {
	// SweepPendingCharges 处理创建早于 before 的一批待办，返回处理掉的条数。
	SweepPendingCharges(ctx context.Context, before time.Time, limit int) (int, error)
}

// SweepLoop 每十分钟把创建超过五分钟、仍然没有终结的流水排进核销队列。它兜住队列
// 满、进程重启与补查遗漏：核销失败不回滚已经交付的回答，流水只能靠补查收尾。取数
// 按上一次尝试时刻轮转，单笔另有尝试上限，积压时更晚的流水也轮得到（ADR-0089）。
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

// ChargeSweepLoop 每十分钟补一次核销申请。结算提交用量与申请核销是两步，进程在
// 中间退出、或者申请那一步读失败时，这段用量只有当天之后的结算按累计差额补，跨日
// 之后没有入口；待办让补查按当天的用量重新申请（ADR-0087）。与 SweepLoop 一样先
// 就地跑一次，一直阻塞到 ctx 结束，调用方要用 goroutine 启动它。
func ChargeSweepLoop(ctx context.Context, store PendingChargeStore, log *slog.Logger) {
	if store == nil {
		return
	}
	periodic.Run(ctx, sweepInterval, func() {
		sweepCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
		defer cancel()
		count, err := store.SweepPendingCharges(sweepCtx, time.Now().Add(-sweepGrace), sweepBatch)
		if err != nil {
			log.Error("sweep the pending nowpay charges", "error", err)
			return
		}
		if count > 0 {
			log.Info("renewed the pending nowpay charges", "rows", count)
		}
	})
}

// Sweep 把一批超过宽限期仍未终结的流水排进核销队列，返回实际入队的条数。pending 的
// 用原参数重试核销，processing 的只查结果，与 Resume 的口径一致。
//
// 每一笔先记一次尝试：取数按上一次尝试时刻轮转，记下这一轮试过之后它就排到后面，
// 积压时更晚的流水下一轮就能轮到。超过上限的那一笔在这一步落成 abandoned，不再入队；
// 取出来之后已经被别的路径终结的流水拿不到状态，这一份也直接丢弃（ADR-0089）。
func (m *Meter) Sweep(ctx context.Context, olderThan time.Time, limit int) (int, error) {
	charges, err := m.ledger.UnsettledGlobal(ctx, olderThan, limit)
	if err != nil {
		return 0, err
	}
	enqueued := 0
	for _, charge := range charges {
		status, err := m.ledger.NoteAttempt(ctx, charge.ID, maxSettleAttempts)
		if err != nil {
			m.log.Error("note a nowpay sweep attempt", "charge_id", charge.ID, "error", err)
			continue
		}
		switch status {
		case StatusPending, StatusProcessing:
			// 按记完尝试之后的状态决定重试还是只查结果，取出来的那一份可能已经过时。
			if m.enqueue(job{charge: charge, verify: status == StatusPending}) {
				enqueued++
			}
		case StatusAbandoned:
			m.log.Warn("gave up a nowpay charge after the attempt limit",
				"charge_id", charge.ID, "attempts", maxSettleAttempts)
		default:
			// 空状态表示这一笔在取出来之后已经终结，补查不用再排。
		}
	}
	return enqueued, nil
}

// MaintenanceLoop 每天记一次对账日志，并按保留期分批删除过期购买入口与终态流水。
// 启动时先跑一次，之后每天一次；任何一步失败只记日志，不影响服务。与 SweepLoop
// 一样会阻塞到 ctx 结束，调用方要用 goroutine 启动它。loc 是配置的自然日、
// 与实例账本记 day 用的是同一个时区（ZHIXIN_TIMEZONE）。
func MaintenanceLoop(ctx context.Context, store MaintenanceStore, loc *time.Location, tokensPerPoint int64, log *slog.Logger) {
	if store == nil {
		return
	}
	if loc == nil {
		loc = payment.ChinaTime()
	}
	periodic.Run(ctx, 24*time.Hour, func() {
		runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), maintenanceLimit)
		defer cancel()
		now := time.Now().In(loc)
		reconcile(runCtx, store, now.Format(time.DateOnly), log)
		reconcileAccounts(runCtx, store, now.AddDate(0, 0, -1).Format(time.DateOnly), tokensPerPoint, log)
		prune(runCtx, store, log)
	})
}

// reconcile 记录核销流水按状态的计数与实例账本当天的用量。
func reconcile(ctx context.Context, store MaintenanceStore, day string, log *slog.Logger) {
	counts, err := store.ChargeStatusCounts(ctx)
	if err != nil {
		log.Error("read the nowpay charge counts", "error", err)
		return
	}
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
		"abandoned", counts[StatusAbandoned],
		"instance_tokens", instance)
}

// reconcileAccounts 核对已经结束的自然日，分别报告申请和确认核销的差额。
func reconcileAccounts(ctx context.Context, store MaintenanceStore, day string, tokensPerPoint int64, log *slog.Logger) {
	accounts, err := store.DailyChargeReconciliation(ctx, day)
	if err != nil {
		log.Error("read the nowpay account charges for reconciliation", "day", day, "error", err)
		return
	}
	for _, account := range accounts {
		required := Points(account.ChargeableTokens, tokensPerPoint)
		unapplied, uncharged := required-account.Applied, required-account.Charged
		if unapplied > 1 || uncharged > 1 {
			log.Warn("nowpay account reconciliation gap",
				"day", day, "user_id", account.UserID, "chargeable_tokens", account.ChargeableTokens,
				"required_points", required, "applied_points", account.Applied, "charged_points", account.Charged,
				"unapplied_points", unapplied, "uncharged_points", uncharged)
		}
	}
}

// prune 按保留期分批删除：购买入口按有效期过期 30 天，核销流水按终态更新时间 180 天，
// 包括确认成功的、确认失败的与补查超过上限不再重试的流水。pending 与 processing 不删，
// 它们还没有结论；只有删号之后失去归属、再也补查不到结果的流水按创建时间例外清理，
// 否则它们会一直积在 pending 上。
func prune(ctx context.Context, store MaintenanceStore, log *slog.Logger) {
	now := time.Now()
	purchases := deleteInBatches(ctx, log, "nowpay_purchase", func(batchCtx context.Context, limit int) (int64, error) {
		return store.DeleteExpiredPurchases(batchCtx, now.AddDate(0, 0, -purchaseKeepDays), limit)
	})
	charges := deleteInBatches(ctx, log, "nowpay_charge", func(batchCtx context.Context, limit int) (int64, error) {
		return store.DeleteTerminalCharges(batchCtx, now.AddDate(0, 0, -chargeKeepDays), limit)
	})
	orphans := deleteInBatches(ctx, log, "nowpay_charge", func(batchCtx context.Context, limit int) (int64, error) {
		return store.DeleteOrphanCharges(batchCtx, now.AddDate(0, 0, -chargeKeepDays), limit)
	})
	log.Info("pruned the nowpay rows", "purchases", purchases, "charges", charges, "orphan_charges", orphans)
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
