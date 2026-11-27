package pg

import (
	"context"
	"errors"
	"fmt"

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

// CheckQuotaSchema 在启动时核对两类额度的预留与计费列，缺列时由自动部署回滚到
// 上一份可执行文件。已有实例按运维手册的增量语句加列。
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

// Settle 把这次预留转成实际用量：reserved 从在途预留里扣掉，actual 记进已结算
// 用量；两者都为 0 且没有拆分时什么也不写。账号用量与实例账本在同一个事务里改，
// 任何一步失败都整体回滚，两边的数字不会各写一半。reserved 与 actual 是计费
// token，usage 是上游报告的原始拆分。实例账本只加减免费额度内的那一段，超出
// 部分由积分承担（ADR-0070）。
//
// attempt 记这次尝试与它是否失败，与 token 两列一起写进同一行：失败按 0 结算时
// token 与预留都回到 0，后台只能靠这两个计数看见失败的调用（ADR-0083）。它们不
// 参与额度判定、预留与核销，判定用的仍是 UsedTokens 的两列。
func (s *Store) Settle(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, reserved, actual int64, usage llmproxy.Usage, attempt llmproxy.SettleAttempt) error {
	if reserved == 0 && actual == 0 && usage.Total() == 0 && attempt.Attempts == 0 {
		return nil
	}
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("pg: 开始额度结算事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// 实例账本的免费段按“当前用量减这次预留”反推，读与写必须在同一个临界区：
	// 不取锁时另一个请求的预留或结算会插在读取与写入之间，实例账与 llm_usage 的
	// 差额会随并发放大。锁与 Reserve 用的同一把，按天串行（ADR-0070、ADR-0073）。
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "llm_usage:"+day); err != nil {
		return fmt.Errorf("pg: 锁定当日额度失败: %w", err)
	}
	q := db.New(tx)
	instanceDelta := actual - reserved
	if limit, limited, err := s.accountLimit(ctx, q, userID); err != nil {
		return err
	} else if limited {
		// 结算前的账号用量含这次预留，减掉它才是这次请求开始时的用量。
		if used, err := usedTokens(ctx, q, userID, date); err != nil {
			return err
		} else {
			free := max(0, limit-max(0, used-reserved))
			instanceDelta = min(actual, free) - min(reserved, free)
		}
	}
	rawEmbedding := int64(0)
	if kind == llmproxy.KindEmbedding && actual > 0 {
		rawEmbedding = usage.Total()
	}
	if err := q.SettleTokens(ctx, db.SettleTokensParams{
		RawEmbeddingTokens: rawEmbedding,
		UserID:             userID, Day: date, Kind: string(kind), ApiKeyID: keyID,
		Reserved: reserved, Actual: actual, InputTokens: usage.Input, CachedTokens: usage.Cached,
		Attempts: attempt.Attempts, Failures: attempt.Failures,
	}); err != nil {
		return fmt.Errorf("pg: 结算额度失败: %w", err)
	}
	if err := q.AddInstanceTokens(ctx, db.AddInstanceTokensParams{Day: date, Delta: instanceDelta}); err != nil {
		return fmt.Errorf("pg: 结算实例额度失败: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("pg: 提交额度结算失败: %w", err)
	}
	// 结算提交之后才申请核销。未确认的核销保留在流水里，下次请求前补查。
	if s.nowpay != nil {
		s.chargeNowPay(ctx, userID, day, date)
	}
	return nil
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
