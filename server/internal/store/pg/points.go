package pg

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/nowpay"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// pointLedger 是积分换算需要的原始量：当天已经申请与已经确认的积分、余额副本的
// 原始余额，以及副本还没有反映的核销。换算统一由 pointBudgetFor 完成，展示、放行
// 与扣减不再各自从这些原始量出发（ADR-0073）。
type pointLedger struct {
	applied            int64
	charged            int64
	balance            int64 // 余额副本的原始值
	unsettled          int64 // 所有记账日还没有结论的核销
	succeededAfterSync int64 // 快照之后才确认成功的核销
	balanceKnown       bool
	syncedAt           time.Time
}

// unreflected 返回余额副本还没有反映的扣减：还没有结论的核销，加上快照之后才
// 确认成功的核销。failed 不在两者的统计范围内。
func (l pointLedger) unreflected() int64 {
	return l.unsettled + l.succeededAfterSync
}

// available 返回副本里尚未被未反映核销占用的积分。它是积分换算唯一的可用余额
// 入口，展示、放行与扣减都从这里取（ADR-0073）。
func (l pointLedger) available() int64 {
	return max(0, l.balance-l.unreflected())
}

func (s *Store) readPointLedger(ctx context.Context, q *db.Queries, userID string, date pgtype.Date) (pointLedger, error) {
	if !s.balanceReady.Load() {
		totals, err := q.DailyChargeTotals(ctx, db.DailyChargeTotalsParams{UserID: text(userID), Day: date})
		if err != nil {
			return pointLedger{}, fmt.Errorf("pg: 读取当日积分核销汇总失败: %w", err)
		}
		return pointLedger{applied: totals.Applied, charged: totals.Charged}, nil
	}
	row, err := q.PointLedgerWithBalance(ctx, db.PointLedgerWithBalanceParams{UserID: userID, Day: date})
	if err != nil {
		return pointLedger{}, fmt.Errorf("pg: 读取积分余额与核销汇总失败: %w", err)
	}
	return pointLedger{
		applied: row.Applied, charged: row.Charged,
		balance:   row.BalancePoints,
		unsettled: row.Unsettled, succeededAfterSync: row.SucceededAfterSync,
		balanceKnown: row.SyncedAt.Valid,
		syncedAt:     row.SyncedAt.Time,
	}, nil
}

// Points 为账号页和管理后台读取积分。余额副本缺失时仍可报告已核销积分，
// 已结算用量及在途预留统一按同一份数据库快照计算。
func (s *Store) Points(ctx context.Context, userID, day string) (llmproxy.PointsView, error) {
	if s.nowpay == nil {
		return llmproxy.PointsView{}, nil
	}
	date, err := pgDate(day)
	if err != nil {
		return llmproxy.PointsView{}, err
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return llmproxy.PointsView{}, fmt.Errorf("pg: 开始积分统计查询失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := db.New(tx)
	ledger, err := s.readPointLedger(ctx, q, userID, date)
	if err != nil {
		return llmproxy.PointsView{}, err
	}
	points := llmproxy.PointsView{Charged: ledger.charged, ChargedKnown: true}
	if !ledger.balanceKnown {
		return points, nil
	}
	points.RemainingKnown = true
	points.SyncedAt = ledger.syncedAt
	limit, limited, err := s.accountLimit(ctx, q, userID)
	if err != nil {
		return llmproxy.PointsView{}, err
	}
	paidUsage := int64(0)
	if limited {
		used, err := usedTokens(ctx, q, userID, date)
		if err != nil {
			return llmproxy.PointsView{}, err
		}
		paidUsage = chargeableTokens(used, limit)
	}
	budget := pointBudgetFor(paidUsage, ledger.applied, ledger.available(), s.nowpay.TokensPerPoint())
	points.Remaining = budget.Points
	return points, nil
}

// paidTokens 返回免费额度之外还能预留的计费 token、是否还有积分可用，以及是否
// 已安排一次余额刷新。余额过期时，这次预留仍按当前副本判断。
func (s *Store) paidTokens(ctx context.Context, q *db.Queries, userID string, date pgtype.Date, used, limit int64) (tokens int64, hasPoints, syncing bool, err error) {
	if !s.balanceReady.Load() {
		return 0, false, false, nil
	}
	ledger, err := s.readPointLedger(ctx, q, userID, date)
	if err != nil {
		return 0, false, false, err
	}
	if !ledger.balanceKnown || time.Since(ledger.syncedAt) > nowpay.BalanceRefreshAfter {
		syncing = s.nowpay.RefreshBalance(ctx, userID)
	}
	if !ledger.balanceKnown {
		return 0, false, syncing, nil
	}
	available := ledger.available()
	budget := pointBudgetFor(chargeableTokens(used, limit), ledger.applied, available, s.nowpay.TokensPerPoint())
	return budget.Tokens, available > 0 || budget.Tokens > 0, syncing, nil
}

// pointBudget 是一次积分换算的三个结果：展示用的尚未占用整积分、放行用的剩余
// 计费 token、扣减用的本次应申请积分。
type pointBudget struct {
	Points int64
	Tokens int64
	Due    int64
}

// pointBudgetFor 是积分口径唯一的换算函数。paidUsage 是当天已经结算、超出免费
// 额度的计费 token；applied 是当天已经申请的积分；available 是余额副本减去未反映
// 核销之后的可用积分，负值表示副本未知；perPoint 是一个积分覆盖的计费 token 数。
//
// 展示与放行先按已结算用量占用的整积分与不足一分的余量收口，剩下的才是尚未占用
// 的整积分与还能预留的 token；扣减只看当天还没有申请的差额，再按可用积分截断。
// 两者从同一份原始量与同一段换算里来，不再各自维护一套修正（ADR-0073）。
func pointBudgetFor(paidUsage, applied, available, perPoint int64) pointBudget {
	if perPoint <= 0 {
		return pointBudget{Points: max(0, available)}
	}
	required := paidUsage / perPoint
	if paidUsage%perPoint != 0 {
		required++
	}
	due := max(0, required-applied)
	if available >= 0 {
		due = min(due, available)
	}
	if available < 0 {
		return pointBudget{Due: due}
	}
	wholeUsed, partialUsed := paidUsage/perPoint, paidUsage%perPoint
	prepaid := max(0, applied-wholeUsed)
	wallet := available - max(0, wholeUsed-applied)
	if wallet < 0 {
		return pointBudget{Due: due}
	}
	var remainder int64
	if partialUsed > 0 {
		switch {
		case prepaid > 0:
			prepaid--
		case wallet > 0:
			wallet--
		default:
			return pointBudget{Due: due}
		}
		remainder = perPoint - partialUsed
	}
	maxWhole := (math.MaxInt64 - remainder) / perPoint
	if wallet > maxWhole || prepaid > maxWhole-wallet {
		return pointBudget{Points: wallet, Tokens: math.MaxInt64, Due: due}
	}
	return pointBudget{Points: wallet, Tokens: (wallet+prepaid)*perPoint + remainder, Due: due}
}
