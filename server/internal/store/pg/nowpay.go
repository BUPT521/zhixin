package pg

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/nowpay"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

var (
	_ nowpay.Ledger        = (*Store)(nil)
	_ nowpay.PurchaseStore = (*Store)(nil)
)

// CheckNowPaySchema 确认即刻收的两张表已经建好。建表不在这条流水线里执行：
// 生产库已有真实交易，改表用可回滚的增量语句，见 server/运维手册.md。
func (s *Store) CheckNowPaySchema(ctx context.Context) error {
	var installed bool
	err := s.pool.QueryRow(ctx, `SELECT to_regclass('nowpay_charge') IS NOT NULL
		AND to_regclass('nowpay_purchase') IS NOT NULL`).Scan(&installed)
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("pg: 即刻收收款需要按 schema.sql 建好 nowpay_charge 与 nowpay_purchase")
	}
	return nil
}

// ReservePoints 在一个事务里比较当天已申请的积分再决定写不写流水。同一天同一账号
// 的申请用事务级 advisory lock 排队：并发结算是不同请求，行锁管不到还没有的行，
// 只看一次已申请量会让两笔各自再扣一次。
func (s *Store) ReservePoints(ctx context.Context, charge nowpay.Charge, required int64) (nowpay.Charge, bool, error) {
	if required <= 0 || charge.UserID == "" || charge.ID == "" {
		return nowpay.Charge{}, false, nil
	}
	date, err := pgDate(charge.Day)
	if err != nil {
		return nowpay.Charge{}, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nowpay.Charge{}, false, fmt.Errorf("pg: 开始积分核销事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`,
		"nowpay:"+charge.UserID+":"+charge.Day); err != nil {
		return nowpay.Charge{}, false, fmt.Errorf("pg: 锁定当日积分核销失败: %w", err)
	}
	q := db.New(tx)
	applied, err := q.AppliedChargePoints(ctx, db.AppliedChargePointsParams{UserID: text(charge.UserID), Day: date})
	if err != nil {
		return nowpay.Charge{}, false, fmt.Errorf("pg: 读取当日已申请积分失败: %w", err)
	}
	if applied >= required {
		return nowpay.Charge{}, false, nil
	}
	charge.Points = required - applied
	if err := q.InsertCharge(ctx, db.InsertChargeParams{
		ID: charge.ID, UserID: text(charge.UserID), Day: date,
		Points: charge.Points, BilledTokens: charge.Tokens,
	}); err != nil {
		return nowpay.Charge{}, false, fmt.Errorf("pg: 写入积分核销流水失败: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nowpay.Charge{}, false, fmt.Errorf("pg: 提交积分核销流水失败: %w", err)
	}
	return charge, true, nil
}

func (s *Store) Unsettled(ctx context.Context, userID string, limit int) ([]nowpay.Charge, error) {
	if limit < 1 {
		return nil, nil
	}
	rows, err := s.q.UnsettledCharges(ctx, db.UnsettledChargesParams{UserID: text(userID), MaxRows: int32(limit)})
	if err != nil {
		return nil, err
	}
	charges := make([]nowpay.Charge, 0, len(rows))
	for _, row := range rows {
		charges = append(charges, nowpay.Charge{
			ID: row.ID, UserID: row.UserID.String, Day: row.Day.Time.Format("2006-01-02"),
			Points: row.Points, Tokens: row.BilledTokens, Status: row.Status,
		})
	}
	return charges, nil
}

// SetStatus 记录一次核销的结果。status 为空时只更新备注，流水停在原状态等下一次
// 补查。
func (s *Store) SetStatus(ctx context.Context, id, status, note string) error {
	params := db.SetChargeStatusParams{ID: id, Note: note}
	if status != "" {
		params.Status = pgtype.Text{String: status, Valid: true}
	}
	return s.q.SetChargeStatus(ctx, params)
}

// LatestPurchase 返回账号最近一次仍在有效期内的购买入口；过期的不再复用，用户重新
// 点购买时按新的请求号创单。
func (s *Store) LatestPurchaseLink(ctx context.Context, userID string, now time.Time) (nowpay.Purchase, bool, error) {
	at, err := pgTime(now)
	if err != nil {
		return nowpay.Purchase{}, false, err
	}
	row, err := s.q.LatestPurchaseLink(ctx, db.LatestPurchaseLinkParams{UserID: text(userID), Now: at})
	if errors.Is(err, pgx.ErrNoRows) {
		return nowpay.Purchase{}, false, nil
	}
	if err != nil {
		return nowpay.Purchase{}, false, err
	}
	return nowpay.Purchase{
		OutRequestNo: row.OutRequestNo, SKU: row.SkuID,
		URL: row.PurchaseUrl, ExpiresAt: row.ExpiresAt.Time,
	}, true, nil
}

func (s *Store) InsertPurchaseLink(ctx context.Context, userID string, purchase nowpay.Purchase) error {
	expires, err := pgTime(purchase.ExpiresAt)
	if err != nil {
		return err
	}
	return s.q.InsertPurchaseLink(ctx, db.InsertPurchaseLinkParams{
		OutRequestNo: purchase.OutRequestNo, UserID: text(userID), SkuID: purchase.SKU,
		PurchaseUrl: purchase.URL, ExpiresAt: expires,
	})
}

// text 把非空账号编号写成可空文本；这两张表在删号之后只解除关联，不删行。
func text(value string) pgtype.Text {
	return pgtype.Text{String: value, Valid: value != ""}
}

// chargeNowPay 算出应当由即刻收积分承担的计费 token 数，交给核销执行器。
//
// 顺序与 ADR-0065 一致：先用当天免费额度，再用 APP 支付时期留在本服务的已购余额，
// 两者都不够的部分才折成积分。没有配置每日额度时免费额度不限，不产生核销。
func (s *Store) chargeNowPay(ctx context.Context, userID, day string, date pgtype.Date) {
	limit, limited, err := s.accountLimit(ctx, s.q, userID, llmproxy.KindChat)
	if err != nil {
		s.log.Error("read the daily quota for nowpay", "user_id", userID, "error", err)
		return
	}
	if !limited {
		return
	}
	used, err := usedTokens(ctx, s.q, userID, date, llmproxy.KindChat)
	if err != nil {
		s.log.Error("read the used tokens for nowpay", "user_id", userID, "error", err)
		return
	}
	var paid int64
	if s.purchasedQuotaEnabled {
		paid, err = s.q.PurchasedTokensUsed(ctx, db.PurchasedTokensUsedParams{
			UserID: userID, Sandbox: s.purchasedQuotaSandbox, Day: date,
		})
		if err != nil {
			s.log.Error("read the purchased tokens for nowpay", "user_id", userID, "error", err)
			return
		}
	}
	if chargeable := chargeableTokens(used, limit, paid); chargeable > 0 {
		s.nowpay.Record(ctx, userID, day, chargeable)
	}
}

// chargeableTokens 返回应当由即刻收积分承担的计费 token 数。先扣当天免费额度，再
// 扣 APP 支付时期已由本地余额承担的用量，剩下的才折成积分：免费额度因此不会因为
// 改成立刻收而变成摆设（ADR-0065、ADR-0067）。
func chargeableTokens(used, limit, legacy int64) int64 {
	return max(0, used-limit-legacy)
}
