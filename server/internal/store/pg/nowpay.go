package pg

import (
	"context"
	"errors"
	"fmt"
	"math"
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

// CheckNowPaySchema 确认即刻收的表与购买入口的新列已经建好。建表不在这条流水线里
// 执行：生产库已有真实交易，改表用可回滚的增量语句，见 server/运维手册.md。
//
// 核销与购买入口这两张表是收款的前提，缺表或购买入口缺列、缺幂等键索引时直接退出，
// 让自动部署回滚到上一份可执行文件（ADR-0074）；余额副本是 2026-11-25 补的一张纯
// 新增表，缺表时只记日志并停用免费额度之外的放行（ADR-0069），这样已经在收款的
// 实例可以先部署新版，再按运维手册建表并重启，不会因为建表顺序停服。
//
// 补查的尝试计数与 abandoned 状态缺任何一项都直接退出（ADR-0089）：缺列时补查写不
// 进去，缺约束时到上限的流水落不成终态，两种情况下积压仍然会饿死更晚的流水。
func (s *Store) CheckNowPaySchema(ctx context.Context) error {
	var installed, balance, purchaseColumns, purchaseIndex, chargePending, chargeColumns, chargeStatus bool
	err := s.pool.QueryRow(ctx, `SELECT
		to_regclass('nowpay_charge') IS NOT NULL AND to_regclass('nowpay_purchase') IS NOT NULL,
		to_regclass('nowpay_balance') IS NOT NULL,
		(SELECT count(*) FROM information_schema.columns
		  WHERE table_name = 'nowpay_purchase'
		    AND column_name IN ('client_request_no', 'state', 'updated_at')) = 3,
		to_regclass('nowpay_purchase_client_request_idx') IS NOT NULL,
		to_regclass('llm_charge_pending') IS NOT NULL,
		(SELECT count(*) FROM information_schema.columns
		  WHERE table_name = 'nowpay_charge'
		    AND column_name IN ('claimed_at', 'attempts', 'last_attempt_at')) = 3,
		(SELECT count(*) FROM pg_constraint
		  WHERE conrelid = to_regclass('nowpay_charge') AND contype = 'c'
		    AND pg_get_constraintdef(oid) LIKE '%abandoned%') > 0`).
		Scan(&installed, &balance, &purchaseColumns, &purchaseIndex, &chargePending,
			&chargeColumns, &chargeStatus)
	if err != nil {
		return err
	}
	if !installed {
		return errors.New("pg: 即刻收收款需要按 schema.sql 建好 nowpay_charge 与 nowpay_purchase")
	}
	if !purchaseColumns || !purchaseIndex {
		return errors.New("pg: nowpay_purchase 缺 client_request_no、state、updated_at 或幂等键索引，" +
			"按运维手册 4.11 的增量语句补齐")
	}
	// 结算事务会写这张待办，缺表时每一次结算都会失败，所以启动时直接拒绝，由自动
	// 部署回滚到上一份可执行文件（ADR-0087）。
	if !chargePending {
		return errors.New("pg: 缺少 llm_charge_pending 表，按运维手册 4.11 建表之后再启动")
	}
	// 认领、尝试计数与轮转时刻是发送与补查的必经步骤，缺列时每一笔核销都发不出去
	// （ADR-0088、ADR-0089）。
	if !chargeColumns {
		return errors.New("pg: nowpay_charge 缺 claimed_at、attempts 或 last_attempt_at 列，" +
			"按运维手册 4.11 加列之后再启动")
	}
	// 状态约束不包含 abandoned 时，补查到上限的流水落不成终态，积压会重新变成死循环。
	if !chargeStatus {
		return errors.New("pg: nowpay_charge 的 status 检查约束还没有包含 abandoned，" +
			"按运维手册 4.11 重建约束之后再启动")
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

// PointCharges 返回账号最近的核销流水，供管理后台查看。没有开通收款时返回空；
// 只读，不改变流水状态。删号之后解除关联的行不再属于任何账号，不返回。
func (s *Store) PointCharges(ctx context.Context, userID string, limit int) ([]llmproxy.PointCharge, error) {
	if s.nowpay == nil || limit < 1 {
		return nil, nil
	}
	rows, err := s.q.RecentChargesByUser(ctx, db.RecentChargesByUserParams{
		UserID: text(userID), MaxRows: int32(limit),
	})
	if err != nil {
		return nil, fmt.Errorf("pg: 读取积分核销流水失败: %w", err)
	}
	charges := make([]llmproxy.PointCharge, 0, len(rows))
	for _, row := range rows {
		charges = append(charges, llmproxy.PointCharge{
			ID: row.ID, Day: row.Day.Time, Points: row.Points,
			BilledTokens: row.BilledTokens, Status: row.Status,
			CreatedAt: row.CreatedAt.Time, UpdatedAt: row.UpdatedAt.Time,
		})
	}
	return charges, nil
}

// RefreshPoints 同步查询一次即刻收的余额并覆盖本地副本，供管理后台的“刷新余额”
// 使用。没有开通收款时返回 false，调用方据此说明这个实例不卖积分。
func (s *Store) RefreshPoints(ctx context.Context, userID string) (bool, error) {
	if s.nowpay == nil {
		return false, nil
	}
	if err := s.nowpay.QueryBalance(ctx, userID); err != nil {
		return true, err
	}
	return true, nil
}

// ReservePoints 在一个事务里比较当天已申请的积分再决定写不写流水。账号的积分
// 余额跨日通用，所以同一账号的核销申请按账号串行，包括跨日结算。
//
// 余额副本也在同一个事务与同一把锁里读，按可用积分收口申请量（ADR-0073）：先算当天
// 还没有申请的差额（累计应扣减去已经申请的积分），再按可用积分截断这个差额。已经申请
// 的积分有一部分已经成功、体现在副本里，另一部分待确认、计入了可用积分的扣减，所以
// 截断的对象只能是差额，不能再拿已经申请的量去减一次可用积分。可用积分为零时不写
// 流水、不调用即刻收；差额大于可用积分时只申请可用积分的那一部分，差额等余额补上之后
// 的下一次结算再算。没有副本时按当天尚未申请的差额核销。
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
		"nowpay:charge:"+charge.UserID); err != nil {
		return nowpay.Charge{}, false, fmt.Errorf("pg: 锁定账号积分核销失败: %w", err)
	}
	q := db.New(tx)
	ledger, err := s.readPointLedger(ctx, q, charge.UserID, date)
	if err != nil {
		return nowpay.Charge{}, false, err
	}
	// available 为负表示副本未知，按整额申请处理。
	available := int64(-1)
	if ledger.balanceKnown {
		available = ledger.balancePoints
	}
	points := chargeDelta(required, ledger.applied, available)
	if points <= 0 {
		return nowpay.Charge{}, false, nil
	}
	charge.Points = points
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

// chargeDelta 算出这次要写进流水的积分：当天还没有申请的差额（累计应扣减去已经申请
// 的积分），再按可用积分截断，截断之后不为负。available 为负表示余额副本未知，按整额
// 申请。已经申请的量不能再从 available 里减一次，因为成功的部分已经反映在副本里、
// 待确认的部分已经计入 available 的扣减，再从差额上减一遍会少申请（ADR-0073）。
func chargeDelta(required, applied, available int64) int64 {
	points := required - applied
	if available >= 0 {
		points = min(points, available)
	}
	return max(points, 0)
}

// ClaimCharge 认领一笔核销流水：把 claimed_at 推到当前时刻，只有这笔流水仍是
// pending、且上一次认领已经超过租约时才成功。状态保持 pending 而不是 processing：
// 认领之后进程可能退出、请求根本没有发出去，processing 只能按请求号查结果，查不到
// 就一直停在 processing（ADR-0088）。
func (s *Store) ClaimCharge(ctx context.Context, id string, lease time.Duration) (bool, error) {
	if id == "" {
		return false, nil
	}
	seconds := int32(math.Ceil(lease.Seconds()))
	claimed, err := s.q.ClaimCharge(ctx, db.ClaimChargeParams{ID: id, LeaseSeconds: seconds})
	if err != nil {
		return false, fmt.Errorf("pg: 认领核销流水失败: %w", err)
	}
	return claimed > 0, nil
}

// NoteAttempt 记一次全局补查的尝试：attempts 加一、last_attempt_at 推到当前时刻，
// 返回落定之后的状态。补查超过上限的那一次把流水落成 abandoned 并写备注，返回这个
// 状态，调用方据此不再发送；流水在这之间已经被别的路径终结时没有可更新的行，返回
// 空状态，这一份直接丢弃（ADR-0089）。
func (s *Store) NoteAttempt(ctx context.Context, id string, maxAttempts int) (string, error) {
	if id == "" || maxAttempts < 1 {
		return "", nil
	}
	row, err := s.q.NoteChargeAttempt(ctx, db.NoteChargeAttemptParams{
		ID: id, MaxAttempts: int32(maxAttempts),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("pg: 记录核销补查尝试失败: %w", err)
	}
	return row.Status, nil
}

// Unsettled 取账号还没有确认结果的流水，供下一轮对话开工前补查。
func (s *Store) Unsettled(ctx context.Context, userID string, limit int) ([]nowpay.Charge, error) {
	if limit < 1 {
		return nil, nil
	}
	rows, err := s.q.UnsettledCharges(ctx, db.UnsettledChargesParams{UserID: text(userID), MaxRows: int32(limit)})
	if err != nil {
		return nil, err
	}
	return chargesFromRows(rows), nil
}

// UnsettledGlobal 取全局创建早于 before、仍未终结的流水，供每十分钟一次的补查兜底；
// 它不按账号过滤，队列满或进程退出时留下的流水由这里清掉（ADR-0073 所在的整改方案）。
// 取数按上一次尝试时刻轮转，反复失败的流水试过一次就排到后面，积压时更晚的流水也
// 轮得到（ADR-0089）。
func (s *Store) UnsettledGlobal(ctx context.Context, before time.Time, limit int) ([]nowpay.Charge, error) {
	if limit < 1 {
		return nil, nil
	}
	at, err := pgTime(before)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.UnsettledChargesGlobal(ctx, db.UnsettledChargesGlobalParams{
		Before: at, MaxRows: int32(limit),
	})
	if err != nil {
		return nil, err
	}
	return chargesFromRows(rows), nil
}

// chargesFromRows 把流水行转成接口类型，供按账号与全局两个查询共用。
func chargesFromRows(rows []db.NowpayCharge) []nowpay.Charge {
	charges := make([]nowpay.Charge, 0, len(rows))
	for _, row := range rows {
		charges = append(charges, nowpay.Charge{
			ID: row.ID, UserID: row.UserID.String, Day: row.Day.Time.Format("2006-01-02"),
			Points: row.Points, Tokens: row.BilledTokens, Status: row.Status,
		})
	}
	return charges
}

// DeleteExpiredPurchases 分批删除有效期早于 before 的购买入口，返回这一批删除的行数。
func (s *Store) DeleteExpiredPurchases(ctx context.Context, before time.Time, limit int) (int64, error) {
	if limit < 1 {
		return 0, nil
	}
	at, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	return s.q.DeleteExpiredPurchases(ctx, db.DeleteExpiredPurchasesParams{
		Before: at, MaxRows: int32(limit),
	})
}

// DeleteTerminalCharges 分批删除终态（succeeded/failed/abandoned）且更新时间早于
// before 的核销流水，返回这一批删除的行数；pending 与 processing 不删。
func (s *Store) DeleteTerminalCharges(ctx context.Context, before time.Time, limit int) (int64, error) {
	if limit < 1 {
		return 0, nil
	}
	at, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	return s.q.DeleteTerminalCharges(ctx, db.DeleteTerminalChargesParams{
		Before: at, MaxRows: int32(limit),
	})
}

// DeleteOrphanCharges 分批删除删号之后失去归属、一直没有结论的核销流水：即刻收的
// 核销与补查都要带买家标识，user_id 被置空的行补查不到结果，只能按创建时间清掉。
// 返回这一批删除的行数。
func (s *Store) DeleteOrphanCharges(ctx context.Context, before time.Time, limit int) (int64, error) {
	if limit < 1 {
		return 0, nil
	}
	at, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	return s.q.DeleteOrphanCharges(ctx, db.DeleteOrphanChargesParams{
		Before: at, MaxRows: int32(limit),
	})
}

// ChargeStatusCounts 按状态统计核销流水，供每日对账日志发现积压。
func (s *Store) ChargeStatusCounts(ctx context.Context) (map[string]int64, error) {
	rows, err := s.q.ChargeStatusCounts(ctx)
	if err != nil {
		return nil, err
	}
	counts := make(map[string]int64, len(rows))
	for _, row := range rows {
		counts[row.Status] = row.Count
	}
	return counts, nil
}

// SetStatus 记录一次核销的结果，并返回这次的确认时刻：status 为空时只更新备注，
// 流水停在原状态等下一次补查。核销成功之后写余额副本要用确认时刻做快照的下限，
// 终态行的 updated_at 就是确认时间，比响应里的快照时刻晚，不取它这笔流水会被算成
// “快照之后才确认”，可用积分比实际少一笔直到下一次查询（ADR-0073）。
func (s *Store) SetStatus(ctx context.Context, id, status, note string) (time.Time, error) {
	params := db.SetChargeStatusParams{ID: id, Note: note}
	if status != "" {
		params.Status = pgtype.Text{String: status, Valid: true}
	}
	at, err := s.q.SetChargeStatus(ctx, params)
	if err != nil {
		return time.Time{}, err
	}
	return at.Time, nil
}

// LatestPurchaseLink 返回账号最近一次可用的购买入口：必须是 ready、带链接且没有过期。
// creating 与 failed 的行不展示，用户重新点购买时按幂等键复用或替换（ADR-0074）。
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
	return purchaseFromRow(row), true, nil
}

// PurchaseByClientRequestNo 按幂等键读一次购买入口。键在账号内唯一，不是全局唯一。
func (s *Store) PurchaseByClientRequestNo(ctx context.Context, userID, clientRequestNo string) (nowpay.Purchase, bool, error) {
	row, err := s.q.PurchaseByClientRequestNo(ctx, db.PurchaseByClientRequestNoParams{
		UserID: text(userID), ClientRequestNo: clientRequestNo,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nowpay.Purchase{}, false, nil
	}
	if err != nil {
		return nowpay.Purchase{}, false, err
	}
	return purchaseFromRow(row), true, nil
}

// CreatePurchaseLink 写入一条 creating 行，purchase_url 为空。同一账号同一幂等键重复
// 写入由唯一索引拒绝，调用方据此判断并发已经有人先建了入口。
func (s *Store) CreatePurchaseLink(ctx context.Context, userID string, purchase nowpay.Purchase) error {
	expires, err := pgTime(purchase.ExpiresAt)
	if err != nil {
		return err
	}
	url := pgtype.Text{}
	if purchase.URL != "" {
		url = pgtype.Text{String: purchase.URL, Valid: true}
	}
	return s.q.InsertPurchaseLink(ctx, db.InsertPurchaseLinkParams{
		OutRequestNo: purchase.OutRequestNo, ClientRequestNo: purchase.ClientRequestNo,
		UserID: text(userID), SkuID: purchase.SKU,
		State:       pgtype.Text{String: purchase.State, Valid: purchase.State != ""},
		PurchaseUrl: url, ExpiresAt: expires,
	})
}

// ReplacePurchaseLink 用新的 out_request_no 替换同一个幂等键的行，回到 creating；失败
// 或超时的入口由此重新创单，旧的请求号不再使用。
func (s *Store) ReplacePurchaseLink(ctx context.Context, userID string, purchase nowpay.Purchase) error {
	expires, err := pgTime(purchase.ExpiresAt)
	if err != nil {
		return err
	}
	updated, err := s.q.ReplacePurchaseLink(ctx, db.ReplacePurchaseLinkParams{
		OutRequestNo: purchase.OutRequestNo, SkuID: purchase.SKU,
		ExpiresAt: expires, UserID: text(userID), ClientRequestNo: purchase.ClientRequestNo,
	})
	if err == nil && updated == 0 {
		return pgx.ErrNoRows
	}
	return err
}

// ReadyPurchaseLink 把 creating 行更新成 ready，写入托管购买页链接与真实有效期。
func (s *Store) ReadyPurchaseLink(ctx context.Context, outRequestNo, url string, expiresAt time.Time) error {
	expires, err := pgTime(expiresAt)
	if err != nil {
		return err
	}
	updated, err := s.q.ReadyPurchaseLink(ctx, db.ReadyPurchaseLinkParams{
		PurchaseUrl: pgtype.Text{String: url, Valid: url != ""},
		ExpiresAt:   expires, OutRequestNo: outRequestNo,
	})
	if err == nil && updated == 0 {
		return pgx.ErrNoRows
	}
	return err
}

// FailPurchaseLink 把 creating 行更新成 failed，保留原 out_request_no 供下一次点击重试。
func (s *Store) FailPurchaseLink(ctx context.Context, outRequestNo string) error {
	return s.q.FailPurchaseLink(ctx, outRequestNo)
}

// LockPurchase 在 (账号, 幂等键) 的会话级 advisory lock 里执行 fn，把同一键的并发点击
// 串行化。锁在 fn 返回之后释放；fn 里还要调用即时收接口，所以不能改用事务级锁，否则
// 创单的一次网络往返会占着一个数据库事务。
func (s *Store) LockPurchase(ctx context.Context, userID, clientRequestNo string, fn func(context.Context) error) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("pg: 获取购买入口连接失败: %w", err)
	}
	defer conn.Release()
	key := "nowpay:purchase:" + userID + ":" + clientRequestNo
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(hashtext($1))`, key); err != nil {
		return fmt.Errorf("pg: 锁定购买入口失败: %w", err)
	}
	defer func() {
		// 解锁用独立上下文：请求可能已经取消，锁不能跟着连接一起留下。
		unlockCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, err := conn.Exec(unlockCtx, `SELECT pg_advisory_unlock(hashtext($1))`, key); err != nil {
			s.log.Error("unlock the nowpay purchase entry", "user_id", userID, "error", err)
		}
	}()
	return fn(ctx)
}

// purchaseFromRow 把购买入口行转成接口类型；user_id 在删号之后为空，这里不返回它。
func purchaseFromRow(row db.NowpayPurchase) nowpay.Purchase {
	return nowpay.Purchase{
		OutRequestNo: row.OutRequestNo, ClientRequestNo: row.ClientRequestNo,
		SKU: row.SkuID, State: row.State,
		URL: row.PurchaseUrl.String, ExpiresAt: row.ExpiresAt.Time,
	}
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
	limit, limited, err := s.accountLimit(ctx, s.q, userID)
	if err != nil {
		s.log.Error("read the daily quota for nowpay", "user_id", userID, "error", err)
		return
	}
	if !limited {
		return
	}
	settled, err := settledTokens(ctx, s.q, userID, date, "")
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
