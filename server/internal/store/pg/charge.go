package pg

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/nowpay"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// pendingChargeKeep 是一条待办最多保留的时间。过了这段时间还没有收齐的用量不再
// 重试，只记一条日志：用户一直没有补充积分，继续每十分钟申请一次没有意义，这条
// 日志留给人工核对（ADR-0087）。
const pendingChargeKeep = 7 * 24 * time.Hour

// SweepPendingCharges 处理创建早于 before 的一批待办：按结算时记下的计费 token 重新
// 申请核销，确认收齐之后删除待办。它兜住结算提交与申请核销之间退出进程、申请那一步
// 读失败，以及当天最后一个请求的超额用量，跨日也能补（ADR-0087）。
//
// 收齐的判断是当天已申请的积分追上了待办折成的积分：结算之后的那次申请如果已经
// 成功，这里只删待办，不会重复申请。
func (s *Store) SweepPendingCharges(ctx context.Context, before time.Time, limit int) (int, error) {
	if s.nowpay == nil || limit < 1 {
		return 0, nil
	}
	at, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	rows, err := s.q.PendingChargesDue(ctx, db.PendingChargesDueParams{Before: at, MaxRows: int32(limit)})
	if err != nil {
		return 0, fmt.Errorf("pg: 读取待申请的核销用量失败: %w", err)
	}
	done := 0
	for _, row := range rows {
		required := nowpay.Points(row.ChargeableTokens, s.nowpay.TokensPerPoint())
		applied, err := s.appliedPoints(ctx, row.UserID, row.Day)
		if err != nil {
			return done, err
		}
		switch {
		case applied >= required:
			// 结算之后的那次申请已经收齐，只剩删除待办。
		case time.Since(row.CreatedAt.Time) > pendingChargeKeep:
			s.log.Warn("drop the pending charge that is still unpaid",
				"user_id", row.UserID, "day", row.Day.Time.Format("2006-01-02"),
				"chargeable_tokens", row.ChargeableTokens, "applied_points", applied, "required_points", required)
		default:
			// 按待办里记下的用量再申请一次；余额不够时只申请余额覆盖的那一部分，
			// 剩下的留给下一轮，用户补充积分之后收齐（ADR-0073）。
			s.nowpay.Record(ctx, row.UserID, row.Day.Time.Format("2006-01-02"), row.ChargeableTokens)
			done++
			continue
		}
		if err := s.deletePendingCharge(ctx, row); err != nil {
			return done, err
		}
		done++
	}
	return done, nil
}

// appliedPoints 返回账号当天已经申请的积分，与核销流水同一口径：判失败的不算，
// 待确认与处理中的算已申请。
func (s *Store) appliedPoints(ctx context.Context, userID string, day pgtype.Date) (int64, error) {
	totals, err := s.q.DailyChargeTotals(ctx, db.DailyChargeTotalsParams{UserID: text(userID), Day: day})
	if err != nil {
		return 0, fmt.Errorf("pg: 读取当天已申请的积分失败: %w", err)
	}
	return totals.Applied, nil
}

// deletePendingCharge 删除一条待办；删除失败时返回错误，下一轮补查还会取到它。
func (s *Store) deletePendingCharge(ctx context.Context, row db.LlmChargePending) error {
	if err := s.q.DeletePendingCharge(ctx, db.DeletePendingChargeParams{UserID: row.UserID, Day: row.Day}); err != nil {
		return fmt.Errorf("pg: 删除待申请的核销用量失败: %w", err)
	}
	return nil
}
