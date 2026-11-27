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

type pointLedger struct {
	applied       int64
	charged       int64
	balancePoints int64 // 余额副本减去尚未反映的核销
	balanceKnown  bool
	syncedAt      time.Time
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
		balancePoints: max(0, row.BalancePoints-row.Unreflected),
		balanceKnown:  row.SyncedAt.Valid,
		syncedAt:      row.SyncedAt.Time,
	}, nil
}

// Points 为账号页和管理后台读取积分。余额副本缺失时仍可报告已核销积分，
// 已结算用量及在途预留统一按同一份数据库快照计算。
func (s *Store) Points(ctx context.Context, userID, day string) (llmproxy.Points, error) {
	if s.nowpay == nil {
		return llmproxy.Points{}, nil
	}
	date, err := pgDate(day)
	if err != nil {
		return llmproxy.Points{}, err
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return llmproxy.Points{}, fmt.Errorf("pg: 开始积分统计查询失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := db.New(tx)
	ledger, err := s.readPointLedger(ctx, q, userID, date)
	if err != nil {
		return llmproxy.Points{}, err
	}
	points := llmproxy.Points{Charged: ledger.charged, ChargedKnown: true}
	if !ledger.balanceKnown {
		return points, nil
	}
	points.Remaining, points.RemainingKnown = ledger.balancePoints, true
	points.SyncedAt = ledger.syncedAt
	limit, limited, err := s.accountLimit(ctx, q, userID)
	if err != nil {
		return llmproxy.Points{}, err
	}
	if limited {
		used, err := usedTokens(ctx, q, userID, date)
		if err != nil {
			return llmproxy.Points{}, err
		}
		points.Remaining, _ = ledger.availability(chargeableTokens(used, limit), s.nowpay.TokensPerPoint())
	}
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
	_, tokens = ledger.availability(chargeableTokens(used, limit), s.nowpay.TokensPerPoint())
	return tokens, ledger.balancePoints > 0 || tokens > 0, syncing, nil
}

// availability 先用当天已申请的积分覆盖超额用量，再用余额覆盖剩余用量。展示的
// 是尚未占用的整积分，预留还可以使用不足一分的余量。流水的 billed_tokens 是
// 申请时的累计用量，核销受余额限制时只有实际申请的积分提供覆盖。
func (l pointLedger) availability(paidUsage, perPoint int64) (points, tokens int64) {
	if perPoint <= 0 {
		return l.balancePoints, 0
	}
	wholeUsed, partialUsed := paidUsage/perPoint, paidUsage%perPoint
	prepaid := max(0, l.applied-wholeUsed)
	wallet := l.balancePoints - max(0, wholeUsed-l.applied)
	if wallet < 0 {
		return 0, 0
	}

	var remainder int64
	if partialUsed > 0 {
		switch {
		case prepaid > 0:
			prepaid--
		case wallet > 0:
			wallet--
		default:
			return 0, 0
		}
		remainder = perPoint - partialUsed
	}
	maxWhole := (math.MaxInt64 - remainder) / perPoint
	if wallet > maxWhole || prepaid > maxWhole-wallet {
		return wallet, math.MaxInt64
	}
	return wallet, (wallet+prepaid)*perPoint + remainder
}
