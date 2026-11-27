package pg

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// SetQuotaLimits 注入配置里的默认每日额度与实例预算；由 llmproxy.NewHandler
// 装配时调用一次，运行期间不再修改，因此不加锁。
func (s *Store) SetQuotaLimits(dailyTokens, instanceDailyTokens int64) {
	s.dailyTokens = dailyTokens
	s.instanceDailyTokens = instanceDailyTokens
}

// Reserve 在一个事务里完成“比较上限、写入预留”。同一天的预留用事务级 advisory
// lock 排成队，因为实例预算是当天所有账号的合计，行锁管不住并发插入的新行；账
// 号额度与实例预算因此在同一个临界区里检查并扣减，不会各自按旧值通过。
//
// 聊天与嵌入先占用共享的每日免费额度，超出部分再用积分余额。余额取本地副本。
// 预留要么拿到 want，要么返回带原因的错误，不按剩余量截断（ADR-0071）。
func (s *Store) Reserve(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, want int64) (int64, error) {
	if want <= 0 {
		return 0, &llmproxy.QuotaExceededError{Reason: llmproxy.QuotaReasonAccount}
	}
	// 上一次结算失败留下的预留先补退，再判断额度：不退的话这笔预留一直占着当天
	// 的额度，用户只看到 429 却看不到用量（ADR-0086）。补退失败只记日志，不影响
	// 这一次预留，全局补查与下一次请求还会再试。
	if _, err := s.retrySettlements(ctx, userID); err != nil {
		s.log.Warn("retry the failed settlement", "user_id", userID, "error", err)
	}
	// 先安排补查尚未确认的核销，不在请求路径上调用即刻收。
	if s.nowpay != nil {
		s.nowpay.Resume(ctx, userID)
	}
	date, err := pgDate(day)
	if err != nil {
		return 0, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("pg: 开始额度预留事务失败: %w", err)
	}
	// 提交成功之后 Rollback 是空操作；任何失败路径都由这里回滚。
	defer func() { _ = tx.Rollback(ctx) }()
	// 锁随事务结束自动释放，进程崩溃也不会留下锁。
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "llm_usage:"+day); err != nil {
		return 0, fmt.Errorf("pg: 锁定当日额度失败: %w", err)
	}
	q := db.New(tx)
	limit, limited, err := s.accountLimit(ctx, q, userID)
	if err != nil {
		return 0, err
	}
	used, err := usedTokens(ctx, q, userID, date)
	if err != nil {
		return 0, err
	}
	freeRemaining := int64(0)
	if limited {
		freeRemaining = max(0, limit-used)
	}
	// 免费额度不够这一次预留时才算余额：额度内的请求不读副本，也不触发查询。
	if paidNeeded := want - freeRemaining; limited && paidNeeded > 0 {
		var paid int64
		var hasPoints, syncing bool
		if s.nowpay != nil {
			paid, hasPoints, syncing, err = s.paidTokens(ctx, q, userID, date, used, limit)
			if err != nil {
				return 0, err
			}
		}
		if paidNeeded > paid {
			// 余额副本缺失或过期、刷新刚刚入队时，这一轮说不准是不是真的不够，
			// 回 syncing 让客户端稍后重试；副本新鲜却不够时，有积分是 points，
			// 没有积分是 account（ADR-0073）。
			reason := llmproxy.QuotaReasonAccount
			switch {
			case syncing:
				reason = llmproxy.QuotaReasonSyncing
			case hasPoints:
				reason = llmproxy.QuotaReasonPoints
			}
			return 0, &llmproxy.QuotaExceededError{Reason: reason}
		}
	}
	// 实例账本只累计免费额度内的部分：超出免费额度、由积分承担的量已经有收入
	// 覆盖，不再占用给免费额度兜底的实例预算（ADR-0070）。
	instance := instancePortion(want, freeRemaining, limited)
	if s.instanceDailyTokens > 0 {
		instanceUsed, err := q.InstanceTokens(ctx, date)
		if err != nil {
			return 0, fmt.Errorf("pg: 读取实例当日用量失败: %w", err)
		}
		if instance > max(0, s.instanceDailyTokens-instanceUsed) {
			return 0, &llmproxy.QuotaExceededError{Reason: llmproxy.QuotaReasonInstance}
		}
	}
	if err := q.AddReservedTokens(ctx, db.AddReservedTokensParams{
		UserID: userID, Day: date, Kind: string(kind), ApiKeyID: keyID, ReservedTokens: want,
	}); err != nil {
		return 0, fmt.Errorf("pg: 写入额度预留失败: %w", err)
	}
	// 实例账本与账号用量在同一个事务里增加：实例预算读的是这份账本，它不随账号
	// 删除，删号因此不会把已经占用的实例预算重新腾出来（ADR-0036）。
	if err := q.AddInstanceTokens(ctx, db.AddInstanceTokensParams{Day: date, Delta: instance}); err != nil {
		return 0, fmt.Errorf("pg: 写入实例额度预留失败: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("pg: 提交额度预留失败: %w", err)
	}
	return want, nil
}

// CheckQuotaSchema 在启动时核对两类额度的预留与计费列，以及结算失败的补偿表；缺
// 列或缺表时由自动部署回滚到上一份可执行文件。已有实例按运维手册的增量语句补齐。
// 补偿表必须在服务启动之前建好：每次预留都会先补退一次，缺表虽然不影响放行，却会
// 让每一次请求都记一条错误日志。
func (s *Store) CheckQuotaSchema(ctx context.Context) error {
	var installed bool
	err := s.pool.QueryRow(ctx, `SELECT count(*) = 3
		FROM information_schema.columns
		WHERE table_schema = current_schema() AND table_name = 'llm_usage'
		  AND column_name IN ('reserved_tokens', 'embedding_billed_tokens', 'embedding_reserved_tokens')`).Scan(&installed)
	if err != nil {
		return fmt.Errorf("pg: 检查 llm_usage 结构失败: %w", err)
	}
	if !installed {
		return errors.New("pg: llm_usage 缺少额度预留或嵌入计费列，按运维手册 4.11 加列之后再启动")
	}
	var settlementTable bool
	err = s.pool.QueryRow(ctx, `SELECT to_regclass('llm_settlement_failure') IS NOT NULL`).Scan(&settlementTable)
	if err != nil {
		return fmt.Errorf("pg: 检查结算失败表失败: %w", err)
	}
	if !settlementTable {
		return errors.New("pg: 缺少 llm_settlement_failure 表，按运维手册 4.11 建表之后再启动")
	}
	return nil
}

// accountLimit 返回账号当天的额度：覆盖值优先，其次配置的默认值；都没有时 ok 为
// false，表示不限额度。
func (s *Store) accountLimit(ctx context.Context, q *db.Queries, userID string) (int64, bool, error) {
	limit, limited, err := quotaOverride(ctx, q, userID)
	if !limited && s.dailyTokens > 0 {
		limit, limited = s.dailyTokens, true
	}
	return limit, limited, err
}

// usedTokens 返回账号当天占用的 token 数，即已结算量与在途预留之和；额度判定
// 必须看这个合计，否则同时发起的请求会各自按旧值通过。没有行时是 0。
func usedTokens(ctx context.Context, q *db.Queries, userID string, day pgtype.Date) (int64, error) {
	used, err := q.UsedTokens(ctx, db.UsedTokensParams{UserID: userID, Day: day})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("pg: 读取账号当日用量失败: %w", err)
	}
	return used, nil
}

// settledTokens 返回账号当天已经结算的计费 token 数，核销与展示只看这一份：在途
// 预留还没有产生实际用量，算进去会在并发时多扣积分（ADR-0071）。
func settledTokens(ctx context.Context, q *db.Queries, userID string, day pgtype.Date, kind llmproxy.Kind) (int64, error) {
	settled, err := q.SettledTokens(ctx, db.SettledTokensParams{UserID: userID, Day: day, Kind: string(kind)})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("pg: 读取账号已结算用量失败: %w", err)
	}
	return settled, nil
}

// QuotaOverrides 批量读取管理后台用到的额度覆盖行；没有覆盖的账号不出现在
// 结果里，调用方按实例默认值显示。一次查询取回一页账号，列表不必逐行读库。
func (s *Store) QuotaOverrides(ctx context.Context, userIDs []string) (map[string]llmproxy.QuotaOverride, error) {
	out := make(map[string]llmproxy.QuotaOverride, len(userIDs))
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := s.q.AccountQuotasByUsers(ctx, userIDs)
	if err != nil {
		return nil, fmt.Errorf("pg: 读取账号额度失败: %w", err)
	}
	for _, row := range rows {
		override := llmproxy.QuotaOverride{Note: row.Note}
		if row.DailyTokens.Valid {
			value := row.DailyTokens.Int64
			override.DailyTokens = &value
		}
		if row.UpdatedAt.Valid {
			override.UpdatedAt = row.UpdatedAt.Time
		}
		out[row.UserID] = override
	}
	return out, nil
}

// SetQuotaOverride 整体替换一个账号的额度覆盖值；额度与备注都为空时删除
// 覆盖行，与内存实现保持同一语义。账号不存在时外键会拒绝写入，调用方先用
// UserByID 核对。
func (s *Store) SetQuotaOverride(ctx context.Context, userID string, daily *int64, note string) error {
	if daily == nil && note == "" {
		return s.ClearQuotaOverride(ctx, userID)
	}
	if err := s.q.UpsertAccountQuota(ctx, db.UpsertAccountQuotaParams{
		UserID:      userID,
		DailyTokens: pgInt8(daily),
		Note:        note,
	}); err != nil {
		return fmt.Errorf("pg: 保存账号额度失败: %w", err)
	}
	return nil
}

func (s *Store) ClearQuotaOverride(ctx context.Context, userID string) error {
	if err := s.q.DeleteAccountQuota(ctx, userID); err != nil {
		return fmt.Errorf("pg: 清除账号额度失败: %w", err)
	}
	return nil
}

// pgInt8 把可空的 int64 转成 pgtype.Int8；nil 写成 NULL，与 llm_quota 的可空列
// 一致。零值不是合法的额度，调用方在处理器里已经拒绝。
func pgInt8(value *int64) pgtype.Int8 {
	if value == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *value, Valid: true}
}

// settlementRetryBatch 是一个账号在一次预留之前最多补退的记录条数：同一个账号同时
// 失败的结算不会很多，处理完这一批还会剩下的由全局补查接手。
const settlementRetryBatch = 4

// settleParams 是一次结算需要的全部参数。Settle 与补退共用同一份，避免两处各写
// 一遍字段清单。
type settleParams struct {
	userID   string
	day      pgtype.Date
	kind     llmproxy.Kind
	keyID    string
	reserved int64
	actual   int64
	usage    llmproxy.Usage
	attempt  llmproxy.SettleAttempt
}

// settleDay 返回这次结算的自然日，advisory lock 与日志都用它；Date 由 pgDate 解析
// 或由数据库读出，两种来源都按同一天表示。
func (p settleParams) settleDay() string { return p.day.Time.Format("2006-01-02") }

// Settle 把这次预留转成实际用量：reserved 从在途预留里扣掉，actual 记进已结算
// 用量；两者都为 0 且没有拆分时什么也不写。账号用量与实例账本在同一个事务里改，
// 任何一步失败都整体回滚，两边的数字不会各写一半。reserved 与 actual 是计费
// token，usage 是上游报告的原始拆分。实例账本只加减免费额度内的那一段，超出
// 部分由积分承担（ADR-0070）。
//
// attempt 记这次尝试与它是否失败，与 token 两列一起写进同一行：失败按 0 结算时
// token 与预留都回到 0，后台只能靠这两个计数看见失败的调用（ADR-0083）。它们不
// 参与额度判定、预留与核销，判定用的仍是 UsedTokens 的两列。
//
// 事务失败时这笔预留还在，而 reserved_tokens 只有结算会减，所以不能只把错误交回
// 调用方：立刻记一条待补偿记录并补退一次，记录也没写成时由每日清掉过去几天的在途
// 预留兜底（ADR-0086）。
func (s *Store) Settle(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, reserved, actual int64, usage llmproxy.Usage, attempt llmproxy.SettleAttempt) error {
	if reserved == 0 && actual == 0 && usage.Total() == 0 && attempt.Attempts == 0 {
		return nil
	}
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	p := settleParams{
		userID: userID, day: date, kind: kind, keyID: keyID,
		reserved: reserved, actual: actual, usage: usage, attempt: attempt,
	}
	if err := s.settleTx(ctx, p, ""); err != nil {
		s.recordSettlementFailure(ctx, p)
		return err
	}
	return nil
}

// settleTx 在一个事务里完成一次结算。deleteID 不为空表示这是补退一条待补偿记录：
// 先删记录再退预留，删不到说明别的进程已经补退过，整个事务回滚，不重复退。
func (s *Store) settleTx(ctx context.Context, p settleParams, deleteID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("pg: 开始额度结算事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// 实例账本的免费段按“当前用量减这次预留”反推，读与写必须在同一个临界区：
	// 不取锁时另一个请求的预留或结算会插在读取与写入之间，实例账与 llm_usage 的
	// 差额会随并发放大。锁与 Reserve 用的同一把，按天串行（ADR-0070、ADR-0073）。
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "llm_usage:"+p.settleDay()); err != nil {
		return fmt.Errorf("pg: 锁定当日额度失败: %w", err)
	}
	q := db.New(tx)
	if deleteID != "" {
		removed, err := q.DeleteSettlementFailure(ctx, deleteID)
		if err != nil {
			return fmt.Errorf("pg: 删除待补偿结算记录失败: %w", err)
		}
		if removed == 0 {
			return nil
		}
	}
	instanceDelta := p.actual - p.reserved
	limit, limited, err := s.accountLimit(ctx, q, p.userID)
	if err != nil {
		return err
	}
	if limited {
		// 结算前的账号用量含这次预留，减掉它才是这次请求开始时的用量。
		used, err := usedTokens(ctx, q, p.userID, p.day)
		if err != nil {
			return err
		}
		free := max(0, limit-max(0, used-p.reserved))
		instanceDelta = min(p.actual, free) - min(p.reserved, free)
	}
	rawEmbedding := int64(0)
	if p.kind == llmproxy.KindEmbedding && p.actual > 0 {
		rawEmbedding = p.usage.Total()
	}
	if err := q.SettleTokens(ctx, db.SettleTokensParams{
		RawEmbeddingTokens: rawEmbedding,
		UserID:             p.userID, Day: p.day, Kind: string(p.kind), ApiKeyID: p.keyID,
		Reserved: p.reserved, Actual: p.actual, InputTokens: p.usage.Input, CachedTokens: p.usage.Cached,
		Attempts: p.attempt.Attempts, Failures: p.attempt.Failures,
	}); err != nil {
		return fmt.Errorf("pg: 结算额度失败: %w", err)
	}
	if err := q.AddInstanceTokens(ctx, db.AddInstanceTokensParams{Day: p.day, Delta: instanceDelta}); err != nil {
		return fmt.Errorf("pg: 结算实例额度失败: %w", err)
	}
	// 核销申请另起一步，用量与待办在同一个事务里落库：进程在那一步之前退出、或者
	// 那一步读失败时，这一行让补查按当天的累计用量重新申请，跨日也不会漏（ADR-0087）。
	// 只算已经结算的用量，在途预留还没有产生费用（ADR-0071）。
	if limited && s.nowpay != nil && p.actual > 0 {
		settled, err := settledTokens(ctx, q, p.userID, p.day, "")
		if err != nil {
			return err
		}
		if chargeable := chargeableTokens(settled, limit); chargeable > 0 {
			if err := q.UpsertPendingCharge(ctx, db.UpsertPendingChargeParams{
				UserID: p.userID, Day: p.day, ChargeableTokens: chargeable,
			}); err != nil {
				return fmt.Errorf("pg: 写入待申请的核销用量失败: %w", err)
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("pg: 提交额度结算失败: %w", err)
	}
	// 结算提交之后才申请核销。未确认的核销保留在流水里，下次请求前补查。
	if s.nowpay != nil {
		s.chargeNowPay(ctx, p.userID, p.settleDay(), p.day)
	}
	return nil
}

// recordSettlementFailure 在结算事务失败之后记一条待补偿记录并马上补退一次：结算
// 超时一类的一次性故障在这一步就能收掉，不必等到下一次请求。记录写不进去时这笔
// 预留会留到当天结束，由每日清掉过去几天的在途预留兜底（ADR-0086）。
//
// 这里用脱离请求的上下文与自己的时限：结算失败常常正是因为请求的截止时间到了，
// 记录不能跟着一起失败。
func (s *Store) recordSettlementFailure(ctx context.Context, p settleParams) {
	if p.reserved <= 0 {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := s.q.AddSettlementFailure(ctx, db.AddSettlementFailureParams{
		UserID: p.userID, Day: p.day, Kind: string(p.kind), ApiKeyID: p.keyID,
		ReservedTokens: p.reserved, BilledTokens: p.actual,
	}); err != nil {
		s.log.Error("record the failed settlement",
			"user_id", p.userID, "day", p.settleDay(), "kind", string(p.kind),
			"reserved_tokens", p.reserved, "billed_tokens", p.actual, "error", err)
		return
	}
	released, err := s.retrySettlements(ctx, p.userID)
	if err != nil {
		s.log.Warn("retry the failed settlement", "user_id", p.userID, "error", err)
		return
	}
	if released > 0 {
		s.log.Warn("released a reservation whose settlement failed",
			"user_id", p.userID, "day", p.settleDay(), "kind", string(p.kind),
			"reserved_tokens", p.reserved, "billed_tokens", p.actual)
	}
}

// retrySettlements 补退一个账号还没有退掉的预留，返回处理掉的条数。它在每次预留
// 之前调用：上一次结算失败留下的预留如果还在，额度判定会先被它挡掉，用户看到的是
// “没用多少却一直 429”（ADR-0086）。
func (s *Store) retrySettlements(ctx context.Context, userID string) (int, error) {
	rows, err := s.q.SettlementFailuresByUser(ctx, db.SettlementFailuresByUserParams{
		UserID: userID, MaxRows: settlementRetryBatch,
	})
	if err != nil {
		return 0, fmt.Errorf("pg: 读取待补偿结算失败: %w", err)
	}
	return s.releaseSettlements(ctx, rows)
}

// SweepSettlementFailures 补退全局创建早于 before 的一批预留，供每十分钟一次的
// 补查兜底：账号不再发请求、或者进程退出之后没有人在请求路径上补退时，由它收尾。
func (s *Store) SweepSettlementFailures(ctx context.Context, before time.Time, maxRows int) (int, error) {
	if maxRows < 1 {
		return 0, nil
	}
	at, err := pgTime(before)
	if err != nil {
		return 0, err
	}
	rows, err := s.q.SettlementFailuresDue(ctx, db.SettlementFailuresDueParams{
		Before: at, MaxRows: int32(maxRows),
	})
	if err != nil {
		return 0, fmt.Errorf("pg: 读取待补偿结算失败: %w", err)
	}
	return s.releaseSettlements(ctx, rows)
}

// releaseSettlements 逐条补退：退预留与删除记录在同一个事务里完成，一条失败就停下，
// 把错误交给调用方记日志，剩下的下一次再处理。
func (s *Store) releaseSettlements(ctx context.Context, rows []db.LlmSettlementFailure) (int, error) {
	done := 0
	for _, row := range rows {
		// 只退预留，不补记已经发生的用量：结算事务是否提交成功在报错时无法判断，
		// 重记一次可能变成重复扣减，少记一次只是这一次的用量没有算进去（ADR-0086）。
		p := settleParams{
			userID: row.UserID, day: row.Day, kind: llmproxy.Kind(row.Kind), keyID: row.ApiKeyID,
			reserved: row.ReservedTokens,
		}
		if err := s.settleTx(ctx, p, row.ID); err != nil {
			return done, err
		}
		done++
	}
	return done, nil
}

// ClearReservationsBefore 清掉 before 之前那些已经不可能再结算的在途预留，返回清掉
// 的行数。一次请求活不过两天，这些预留既没有结算也没有补退记录（进程在结算之前
// 退出，或者失败记录也写不进去），留着只会让当天之后的账一直挂着一份占用量。
func (s *Store) ClearReservationsBefore(ctx context.Context, before time.Time) (int64, error) {
	date, err := pgDate(before.Format("2006-01-02"))
	if err != nil {
		return 0, err
	}
	cleared, err := s.q.ClearReservationsBefore(ctx, date)
	if err != nil {
		return 0, fmt.Errorf("pg: 清理过期的在途预留失败: %w", err)
	}
	return cleared, nil
}

// InstanceUsed 返回实例当天的总用量，供实例预算与展示使用。读数来自
// llm_instance_usage，与账号是否还在无关。
func (s *Store) InstanceUsed(ctx context.Context, day string) (int64, error) {
	date, err := pgDate(day)
	if err != nil {
		return 0, err
	}
	used, err := s.q.InstanceTokens(ctx, date)
	if err != nil {
		return 0, fmt.Errorf("pg: 读取实例当日用量失败: %w", err)
	}
	return used, nil
}

// instancePortion 返回一次预留里应当记进实例账本的计费 token 数：只有免费额度
// 内的部分占用实例预算，超出免费额度、由积分承担的部分不占（ADR-0070）。
func instancePortion(reserved, freeRemaining int64, limited bool) int64 {
	if !limited {
		return reserved
	}
	return min(reserved, freeRemaining)
}
