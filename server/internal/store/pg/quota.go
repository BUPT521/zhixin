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
func (s *Store) Reserve(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, want int64) (int64, error) {
	if want <= 0 {
		return 0, llmproxy.ErrQuotaExceeded
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
	free := max(0, limit-used)
	reserved := want
	if limited {
		reserved = min(reserved, free)
	}
	if s.instanceDailyTokens > 0 {
		instanceUsed, err := q.InstanceTokens(ctx, date)
		if err != nil {
			return 0, fmt.Errorf("pg: 读取实例当日用量失败: %w", err)
		}
		reserved = min(reserved, s.instanceDailyTokens-instanceUsed)
	}
	if reserved <= 0 {
		return 0, llmproxy.ErrQuotaExceeded
	}
	if err := q.AddTokens(ctx, db.AddTokensParams{
		UserID: userID, Day: date, Kind: string(kind), ApiKeyID: keyID, Tokens: reserved,
	}); err != nil {
		return 0, fmt.Errorf("pg: 写入额度预留失败: %w", err)
	}
	// 实例账本与账号用量在同一个事务里增加：实例预算读的是这份账本，它不随账号
	// 删除，删号因此不会把已经占用的实例预算重新腾出来（ADR-0036）。
	if err := q.AddInstanceTokens(ctx, db.AddInstanceTokensParams{Day: date, Delta: reserved}); err != nil {
		return 0, fmt.Errorf("pg: 写入实例额度预留失败: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("pg: 提交额度预留失败: %w", err)
	}
	return reserved, nil
}

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

// usedTokens 返回账号当天已用的 token 数；没有行时是 0。
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

// Settle 按实际用量调整预留；差额为 0 时只记统计用的拆分，不写额度。账号用量与
// 实例账本在同一个事务里改，任何一步失败都整体回滚，两边的数字不会各写一半。
// reserved 与 actual 是计费 token，usage 是上游报告的原始拆分。
func (s *Store) Settle(ctx context.Context, userID, day string, kind llmproxy.Kind, keyID string, reserved, actual int64, usage llmproxy.Usage) error {
	delta := actual - reserved
	if delta == 0 && usage.Total() == 0 {
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
	if err := q.SettleTokens(ctx, db.SettleTokensParams{
		UserID: userID, Day: date, Kind: string(kind), ApiKeyID: keyID,
		Delta: delta, InputTokens: usage.Input, CachedTokens: usage.Cached,
	}); err != nil {
		return fmt.Errorf("pg: 结算额度失败: %w", err)
	}
	if err := q.AddInstanceTokens(ctx, db.AddInstanceTokensParams{Day: date, Delta: delta}); err != nil {
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
