package llmproxy

import (
	"context"
	"errors"
	"sync"
)

// Quota tracks tokens used per account, model kind, and local day. The day key is a
// YYYY-MM-DD string in the configured time zone (ZHIXIN_TIMEZONE).
//
// 托管额度先预留再结算：转发前按请求体大小估算一个 token 上限并 Reserve，转发
// 结束后按提供方返回的 usage Settle。预留让同时发起的请求在同一个额度上互相
// 看得见，结算再按实际用量多退少补。
//
// DailyLimit 读取按账号调整过的每日额度；没有覆盖行时返回 ok=false，由代理用
// 聊天与嵌入各自的默认额度。管理员在 llm_quota 表里调整，见 server/README。
type Quota interface {
	Used(ctx context.Context, userID, day string, kind Kind) (int64, error)
	Add(ctx context.Context, userID, day string, kind Kind, tokens int64) error
	DailyLimit(ctx context.Context, userID string, kind Kind) (int64, bool, error)
	// Reserve 原子预留 want 个 token，返回实际预留量。账号额度或实例预算已经用
	// 完时返回 ErrQuotaExceeded；剩余不足 want 时按剩余量预留，调用方照常转发。
	Reserve(ctx context.Context, userID, day string, kind Kind, want int64) (reserved int64, err error)
	// Settle 按实际用量调整预留：actual 大于 reserved 时补记差额，小于时退回。
	Settle(ctx context.Context, userID, day string, kind Kind, reserved, actual int64) error
	// InstanceUsed 返回实例当天的账本用量，用于展示与判断实例预算。账本与账号
	// 无关，删号不会减少它。
	InstanceUsed(ctx context.Context, day string) (int64, error)
}

// ErrQuotaExceeded 表示账号当日额度或实例总预算已经用完；代理据此回 429
// quota_exceeded，调用方用 errors.Is 判断。
var ErrQuotaExceeded = errors.New("llmproxy: 托管额度不足")

// quotaLimits 是配额实现接收上限的约定：默认每日额度与实例预算只有配置一处
// 来源，NewHandler 装配时注入给实现，Reserve 用它做原子比较。内存与 PostgreSQL
// 两种实现都实现了这个方法。
type quotaLimits interface {
	SetQuotaLimits(dailyTokens, embeddingDailyTokens, instanceDailyTokens int64)
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu     sync.Mutex
	used   map[[3]string]int64
	limits map[[2]string]int64
	// instance 是实例当天的账本，按自然日记 token 数；它与 used 分开保存，删号
	// 只清 used，已经占用的实例预算因此不会重新腾出来（ADR-0036）。
	instance map[string]int64

	// dailyTokens 与 instanceTokens 是配置里的默认额度与实例预算，由 NewHandler
	// 装配时注入；小于等于 0 表示不限。
	dailyTokens          int64
	embeddingDailyTokens int64
	instanceTokens       int64
}

func NewMemoryQuota() *MemoryQuota {
	return &MemoryQuota{
		used:     map[[3]string]int64{},
		limits:   map[[2]string]int64{},
		instance: map[string]int64{},
	}
}

// SetQuotaLimits 注入配置里的默认每日额度与实例预算；由 NewHandler 在装配时调用。
func (m *MemoryQuota) SetQuotaLimits(dailyTokens, embeddingDailyTokens, instanceDailyTokens int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dailyTokens = dailyTokens
	m.embeddingDailyTokens = embeddingDailyTokens
	m.instanceTokens = instanceDailyTokens
}

func (m *MemoryQuota) Used(_ context.Context, userID, day string, kind Kind) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.used[[3]string{userID, day, string(kind)}], nil
}

func (m *MemoryQuota) Add(_ context.Context, userID, day string, kind Kind, tokens int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.used[[3]string{userID, day, string(kind)}] += tokens
	return nil
}

// Reserve 在锁里完成比较与扣减，同一账号或同一天的并发请求不会各自读到旧值。
func (m *MemoryQuota) Reserve(_ context.Context, userID, day string, kind Kind, want int64) (int64, error) {
	if want <= 0 {
		return 0, ErrQuotaExceeded
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	key := [3]string{userID, day, string(kind)}
	// reserved 先按请求量取，再按账号剩余量截断；比较的对象必须是本次请求量，不能是
	// 上一次截断后的值，否则剩余量够用时也会被截成 0（剩余 60 时请求 40 会被拒绝）。
	reserved := want
	if limit, ok := m.accountLimitLocked(userID, kind); ok {
		reserved = min(want, limit-m.used[key])
	}
	if m.instanceTokens > 0 {
		reserved = min(reserved, m.instanceTokens-m.instance[day])
	}
	if reserved <= 0 {
		return 0, ErrQuotaExceeded
	}
	m.used[key] += reserved
	m.instance[day] += reserved
	return reserved, nil
}

func (m *MemoryQuota) Settle(_ context.Context, userID, day string, kind Kind, reserved, actual int64) error {
	if actual == reserved {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	key := [3]string{userID, day, string(kind)}
	used := m.used[key] + actual - reserved
	if used < 0 {
		// 预留与结算之间没有别的写路径，负数只可能来自调用方给错参数；归零而不是
		// 留下负用量，查询与上限比较都不会因此失真。
		used = 0
	}
	m.used[key] = used
	instance := m.instance[day] + actual - reserved
	if instance < 0 {
		instance = 0
	}
	m.instance[day] = instance
	return nil
}

func (m *MemoryQuota) InstanceUsed(_ context.Context, day string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.instance[day], nil
}

// accountLimitLocked 返回账号当天的额度：覆盖值优先，其次配置的默认值；都没有
// 时 ok 为 false，表示不限额度。调用方必须持有 m.mu。
func (m *MemoryQuota) accountLimitLocked(userID string, kind Kind) (int64, bool) {
	if limit, ok := m.limits[[2]string{userID, string(kind)}]; ok {
		return limit, true
	}
	limit := m.dailyTokens
	if kind == KindEmbedding {
		limit = m.embeddingDailyTokens
	}
	return limit, limit > 0
}

// SetDailyLimit 调整一个账号的每日额度，供本地联调与测试使用；生产上改
// llm_quota 表。
func (m *MemoryQuota) SetDailyLimit(userID string, tokens int64) {
	m.SetKindLimit(userID, KindChat, tokens)
}

// SetKindLimit 调整一个账号某类模型的每日额度。
func (m *MemoryQuota) SetKindLimit(userID string, kind Kind, tokens int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.limits[[2]string{userID, string(kind)}] = tokens
}

func (m *MemoryQuota) DailyLimit(_ context.Context, userID string, kind Kind) (int64, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	limit, ok := m.limits[[2]string{userID, string(kind)}]
	return limit, ok, nil
}

// DeleteUser 清掉账号自己的用量与额度覆盖值。实例账本不在这里清：它记录的是
// 提供方已经计费的用量，删号不会让那笔费用消失（ADR-0036）。
func (m *MemoryQuota) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k := range m.used {
		if k[0] == userID {
			delete(m.used, k)
		}
	}
	delete(m.limits, [2]string{userID, string(KindChat)})
	delete(m.limits, [2]string{userID, string(KindEmbedding)})
	return nil
}
