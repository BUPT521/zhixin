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
func (s *Store) SetQuotaLimits(dailyTokens, embeddingDailyTokens, instanceDailyTokens int64) {
	s.dailyTokens = dailyTokens
	s.embeddingDailyTokens = embeddingDailyTokens
	s.instanceDailyTokens = instanceDailyTokens
}

// Reserve 在一个事务里完成“比较上限、写入预留”。同一天的预留用事务级 advisory
// lock 排成队，因为实例预算是当天所有账号的合计，行锁管不住并发插入的新行；账
// 号额度与实例预算因此在同一个临界区里检查并扣减，不会各自按旧值通过。
//
// 账号额度分两段：当天免费额度先算，聊天在免费额度之外再加上即刻收余额折成的
// token（ADR-0069），嵌入只有免费额度。余额取本地副本，这一段不调用即刻收。
// 预留要么拿到 want，要么返回带原因的错误，不按剩余量截断（ADR-0071）。
func (s *Store) Reserve(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, want int64) (int64, error) {
	if want <= 0 {
		return 0, &llmproxy.QuotaExceededError{Reason: llmproxy.QuotaReasonAccount}
	}
	// 每轮对话开工前先把上一轮没有确认结果的核销补查一次：补查只排进队列，不在这
	// 条请求路径上调用即刻收，失败也不影响这一轮（ADR-0067）。
	if s.nowpay != nil && kind == llmproxy.KindChat {
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
	limit, limited, err := s.accountLimit(ctx, q, userID, kind)
	if err != nil {
		return 0, err
	}
	used, err := usedTokens(ctx, q, userID, date, kind)
	if err != nil {
		return 0, err
	}
	freeRemaining := int64(0)
	if limited {
		freeRemaining = max(0, limit-used)
	}
	paid := int64(0)
	hasPoints := false
	if limited {
		allowed := freeRemaining
		// 免费额度不够这一次预留时才算余额：额度内的请求不读副本，也不触发查询。
		if allowed < want && kind == llmproxy.KindChat && s.nowpay != nil {
			paid, hasPoints, err = s.paidTokens(ctx, q, userID, date, used, limit)
			if err != nil {
				return 0, err
			}
			allowed += paid
		}
		if want > allowed {
			// 有可用积分却仍然不够，说明缺的是积分；没有积分就是免费额度用完。
			reason := llmproxy.QuotaReasonAccount
			if hasPoints {
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

// CheckQuotaSchema 确认 llm_usage 已经有 reserved_tokens 列（ADR-0071）。预留与
// 已结算用量分开记的前提是这一列，缺列时每条模型请求都会写失败，所以启动时直接
// 拒绝，让自动部署回滚到上一份可执行文件；加列由运维手册里的增量语句完成。
func (s *Store) CheckQuotaSchema(ctx context.Context) error {
	var installed bool
	err := s.pool.QueryRow(ctx, `SELECT EXISTS (
		SELECT 1 FROM information_schema.columns
		WHERE table_schema = current_schema()
		  AND table_name = 'llm_usage' AND column_name = 'reserved_tokens')`).Scan(&installed)
	if err != nil {
		return fmt.Errorf("pg: 检查 llm_usage 结构失败: %w", err)
	}
	if !installed {
		return errors.New("pg: llm_usage 缺少 reserved_tokens 列，按运维手册 4.11 加列之后再启动")
	}
	return nil
}

// accountLimit 返回账号当天的额度：覆盖值优先，其次配置的默认值；都没有时 ok 为
// false，表示不限额度。
func (s *Store) accountLimit(ctx context.Context, q *db.Queries, userID string, kind llmproxy.Kind) (int64, bool, error) {
	fallback := s.dailyTokens
	if kind == llmproxy.KindEmbedding {
		fallback = s.embeddingDailyTokens
	}
	limit, limited, err := quotaOverride(ctx, q, userID, kind)
	if !limited && fallback > 0 {
		limit, limited = fallback, true
	}
	return limit, limited, err
}

// usedTokens 返回账号当天占用的 token 数，即已结算量与在途预留之和；额度判定
// 必须看这个合计，否则同时发起的请求会各自按旧值通过。没有行时是 0。
func usedTokens(ctx context.Context, q *db.Queries, userID string, day pgtype.Date, kind llmproxy.Kind) (int64, error) {
	used, err := q.UsedTokens(ctx, db.UsedTokensParams{UserID: userID, Day: day, Kind: string(kind)})
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

// Settle 把这次预留转成实际用量：reserved 从在途预留里扣掉，actual 记进已结算
// 用量；两者都为 0 且没有拆分时什么也不写。账号用量与实例账本在同一个事务里改，
// 任何一步失败都整体回滚，两边的数字不会各写一半。reserved 与 actual 是计费
// token，usage 是上游报告的原始拆分。实例账本只加减免费额度内的那一段，超出
// 部分由积分承担（ADR-0070）。
func (s *Store) Settle(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, reserved, actual int64, usage llmproxy.Usage) error {
	if reserved == 0 && actual == 0 && usage.Total() == 0 {
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
	q := db.New(tx)
	instanceDelta := actual - reserved
	if limit, limited, err := s.accountLimit(ctx, q, userID, kind); err != nil {
		return err
	} else if limited {
		// 结算前的账号用量含这次预留，减掉它才是这次请求开始时的用量。
		if used, err := usedTokens(ctx, q, userID, date, kind); err != nil {
			return err
		} else {
			free := max(0, limit-max(0, used-reserved))
			instanceDelta = min(actual, free) - min(reserved, free)
		}
	}
	if err := q.SettleTokens(ctx, db.SettleTokensParams{
		UserID: userID, Day: date, Kind: string(kind), ApiKeyID: keyID,
		Reserved: reserved, Actual: actual, InputTokens: usage.Input, CachedTokens: usage.Cached,
	}); err != nil {
		return fmt.Errorf("pg: 结算额度失败: %w", err)
	}
	if err := q.AddInstanceTokens(ctx, db.AddInstanceTokensParams{Day: date, Delta: instanceDelta}); err != nil {
		return fmt.Errorf("pg: 结算实例额度失败: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("pg: 提交额度结算失败: %w", err)
	}
	// 结算提交之后才算这笔用量：回答已经发给用户，核销失败不回滚，留在流水里由下
	// 一轮请求前补查（ADR-0067）。
	if s.nowpay != nil && kind == llmproxy.KindChat {
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
