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
	_ nowpay.BalanceStore  = (*Store)(nil)
)

// CheckNowPaySchema 确认即刻收的表已经建好。建表不在这条流水线里执行：生产库已有
// 真实交易，改表用可回滚的增量语句，见 server/运维手册.md。
//
// 核销与购买入口这两张表是收款的前提，缺表直接退出；余额副本是 2026-11-25 补的
// 一张纯新增表，缺表时只记日志并停用免费额度之外的放行（ADR-0069），这样已经在
// 收款的实例可以先部署新版，再按运维手册建表并重启，不会因为建表顺序停服。
func (s *Store) CheckNowPaySchema(ctx context.Context) error {
	var installed, balance bool
	err := s.pool.QueryRow(ctx, `SELECT to_regclass('nowpay_charge') IS NOT NULL
		AND to_regclass('nowpay_purchase') IS NOT NULL,
		to_regclass('nowpay_balance') IS NOT NULL`).Scan(&installed, &balance)
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("pg: 即刻收收款需要按 schema.sql 建好 nowpay_charge 与 nowpay_purchase")
	}
	s.balanceReady.Store(balance)
	if !balance {
		s.log.Error("nowpay_balance is missing: chat stays limited to the free allowance until the table is created and the service restarts",
			"table", "nowpay_balance")
	}
	return nil
}

// SaveBalance 用即刻收报告的剩余积分覆盖本地余额副本（ADR-0069）。asOf 是这份余额
// 对应的快照时刻：查询响应带 as_of_time 时用它，核销结果没有携带时用发起核销的时刻。
// 副本只用于判断能不能放行，真正的余额在支付宝一侧；晚到的旧快照不会覆盖新副本
// （ADR-0073）。账号已经删除时外键拒绝写入，按错误返回。副本表还没建好时不做任何
// 事，等建表并重启之后才写。
func (s *Store) SaveBalance(ctx context.Context, userID string, remaining int64, asOf time.Time) error {
	if userID == "" || !s.balanceReady.Load() {
		return nil
	}
	syncedAt, err := pgTime(asOf)
	if err != nil {
		return err
	}
	return s.q.SaveBalance(ctx, db.SaveBalanceParams{
		UserID: userID, RemainingPoints: remaining, SyncedAt: syncedAt,
	})
}

// Points 返回账号的积分视图：当天已经核销成功的积分与可用积分。没有配置即刻收、
// 或者余额副本表还没建好时 Known 为 false，账号页不显示这两行。可用积分与预留
// 放行用同一个口径：副本减去还没有反映的核销，再减去当天已经结算、还没有记进流水
// 的计费量折成的积分，账号页显示的数因此不会大于实际能放行的量（ADR-0073）。
func (s *Store) Points(ctx context.Context, userID, day string) (llmproxy.Points, error) {
	if s.nowpay == nil || !s.balanceReady.Load() {
		return llmproxy.Points{}, nil
	}
	date, err := pgDate(day)
	if err != nil {
		return llmproxy.Points{}, err
	}
	charged, err := s.q.ChargedPoints(ctx, db.ChargedPointsParams{UserID: text(userID), Day: date})
	if err != nil {
		return llmproxy.Points{}, fmt.Errorf("pg: 读取当天已核销积分失败: %w", err)
	}
	limit, limited, err := s.accountLimit(ctx, s.q, userID, llmproxy.KindChat)
	if err != nil {
		return llmproxy.Points{}, err
	}
	used, err := settledTokens(ctx, s.q, userID, date, llmproxy.KindChat)
	if err != nil {
		return llmproxy.Points{}, err
	}
	view, err := s.balancePoints(ctx, s.q, userID, date, used, limit, limited)
	if err != nil {
		return llmproxy.Points{}, err
	}
	if !view.known {
		return llmproxy.Points{Charged: charged}, nil
	}
	return llmproxy.Points{Charged: charged, Remaining: view.points, Known: true}, nil
}

// AvailablePoints 返回本地余额副本里的可用积分，供核销侧决定这次申请多少。与
// paidTokens 的口径一致：副本表还没建好或账号还没有同步过余额时返回 known=false，
// 调用方按未知处理，不按副本截断申请量；读取失败只返回错误，不伪装成零余额。
func (s *Store) AvailablePoints(ctx context.Context, userID string) (int64, bool, error) {
	if userID == "" || !s.balanceReady.Load() {
		return 0, false, nil
	}
	balance, err := s.q.BalanceForReserve(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, fmt.Errorf("pg: 读取积分余额副本失败: %w", err)
	}
	return balance.RemainingPoints, true, nil
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

// text 把非空账号编号写成可空文本；流水与购买入口这两张表在删号之后只解除关联，
// 不删行，余额副本随账号一起删除。
func text(value string) pgtype.Text {
	return pgtype.Text{String: value, Valid: value != ""}
}

// chargeNowPay 算出当天累计应当由即刻收积分承担的计费 token 数，交给核销执行器；
// 执行器再减去当天已申请的积分，只补差额（ADR-0067）。
//
// 先用当天免费额度，超出部分才折成积分。没有配置每日额度时免费额度不限，不产生
// 核销。累计量只算已经结算的用量：在途预留还没有产生实际费用，算进去会让并发
// 请求多扣积分（ADR-0071）。
func (s *Store) chargeNowPay(ctx context.Context, userID, day string, date pgtype.Date) {
	limit, limited, err := s.accountLimit(ctx, s.q, userID, llmproxy.KindChat)
	if err != nil {
		s.log.Error("read the daily quota for nowpay", "user_id", userID, "error", err)
		return
	}
	if !limited {
		return
	}
	settled, err := settledTokens(ctx, s.q, userID, date, llmproxy.KindChat)
	if err != nil {
		s.log.Error("read the settled tokens for nowpay", "user_id", userID, "error", err)
		return
	}
	if chargeable := chargeableTokens(settled, limit); chargeable > 0 {
		s.nowpay.Record(ctx, userID, day, chargeable)
	}
}

// chargeableTokens 返回应当由即刻收积分承担的计费 token 数：先扣当天免费额度，
// 剩下的才折成积分（ADR-0067）。
func chargeableTokens(used, limit int64) int64 {
	return max(0, used-limit)
}

// paidTokens 返回免费额度之外还可以由积分承担、因此可以放行的计费 token 数，账号
// 是否有已购积分，以及副本是否刚刚排过刷新。第三个返回值用于区分 429 的原因：
// 副本缺失或过期、查询刚刚入队时是 syncing，客户端提示稍后重试而不是引导购买；
// 副本新鲜却不够时才分 points 与 account（ADR-0073）。
//
// 余额取本地副本，预留因此不在请求路径上调用即刻收（ADR-0069）。副本缺失或距上次
// 快照超过 nowpay.BalanceRefreshAfter 时排一次异步查询，并报告这次是否真的入队
// （同一账号一分钟内只入队一次）；这一轮仍按现有副本判断。
func (s *Store) paidTokens(ctx context.Context, q *db.Queries, userID string, date pgtype.Date, used, limit int64) (int64, bool, bool, error) {
	view, err := s.balancePoints(ctx, q, userID, date, used, limit, true)
	if err != nil {
		return 0, false, false, err
	}
	syncing := false
	if view.stale {
		syncing = s.nowpay.RefreshBalance(ctx, userID)
	}
	// hasPoints 看扣掉当天未记流水的计费量之前的余额：积分都在在途请求里时，用户
	// 手上确实还有已购积分，429 按 points 说“不够这一次”，不按 account 说没有积分。
	return view.points * s.nowpay.TokensPerPoint(), view.raw > 0, syncing, nil
}

// balanceView 是余额副本的读数。points 是可用积分，raw 是副本减去没有反映的核销、
// 还没有扣当天未记流水的计费量。
type balanceView struct {
	points int64
	raw    int64
	known  bool
	stale  bool
}

// balancePoints 读余额副本并算出可用积分：副本减去还没有反映的核销，再减去当天
// 已经发生、还没有记进流水的计费量折成的积分（向下取整）。known 为假表示余额表
// 未就绪或账号还没有副本；stale 表示副本缺失或距快照超过需要重新查询的间隔，调用
// 方据此决定是否排一次刷新。账号页的剩余积分与 paidTokens 共用这一处，显示的数
// 因此不会大于实际能放行的量（ADR-0073）。
func (s *Store) balancePoints(ctx context.Context, q *db.Queries, userID string, date pgtype.Date, used, limit int64, limited bool) (balanceView, error) {
	// 副本表还没建好时只放行免费额度，不去查一张不存在的表。
	if !s.balanceReady.Load() {
		return balanceView{}, nil
	}
	balance, err := q.BalanceForReserve(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return balanceView{stale: true}, nil
	}
	if err != nil {
		return balanceView{}, fmt.Errorf("pg: 读取积分余额副本失败: %w", err)
	}
	unreflected, err := q.UnreflectedChargePoints(ctx, db.UnreflectedChargePointsParams{
		UserID: text(userID), AsOf: balance.SyncedAt,
	})
	if err != nil {
		return balanceView{}, fmt.Errorf("pg: 读取副本没有反映的核销积分失败: %w", err)
	}
	charged, err := q.ChargedTokens(ctx, db.ChargedTokensParams{UserID: text(userID), Day: date})
	if err != nil {
		return balanceView{}, fmt.Errorf("pg: 读取当天已核销的计费量失败: %w", err)
	}
	unbilled := int64(0)
	if limited {
		unbilled = max(chargeableTokens(used, limit)-charged, 0)
	}
	view := balanceView{
		raw:   max(balance.RemainingPoints-unreflected, 0),
		known: true,
		stale: time.Since(balance.SyncedAt.Time) > nowpay.BalanceRefreshAfter,
	}
	view.points = view.raw
	if unbilled > 0 {
		if perPoint := s.nowpay.TokensPerPoint(); perPoint > 0 {
			view.points = max(view.points-unbilled/perPoint, 0)
		}
	}
	return view, nil
}
