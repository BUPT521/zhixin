package llmproxy

import (
	"context"
	"errors"
	"sync"
)

// Quota tracks tokens used per account per local day. The day key is a
// YYYY-MM-DD string in the configured time zone (ZHIXIN_TIMEZONE).
//
// 托管额度先预留再结算：转发前按请求体大小估算一个 token 上限并 Reserve，转发
// 结束后按提供方返回的 usage Settle。预留让同时发起的请求在同一个额度上互相
// 看得见，结算再按实际用量多退少补。
//
// DailyLimit 读取按账号调整过的每日额度；没有覆盖行时返回 ok=false，由代理用
// ZHIXIN_LLM_DAILY_TOKENS。管理员在 llm_quota 表里调整，见 server/README。
type Quota interface {
	Used(ctx context.Context, userID, day string) (int64, error)
	Add(ctx context.Context, userID, day string, tokens int64) error
	DailyLimit(ctx context.Context, userID string) (int64, bool, error)
	// Reserve 原子预留 want 个 token，返回实际预留量。账号额度或实例预算已经用
	// 完时返回 ErrQuotaExceeded；剩余不足 want 时按剩余量预留，调用方照常转发。
	Reserve(ctx context.Context, userID, day string, want int64) (reserved int64, err error)
	// Settle 按实际用量调整预留：actual 大于 reserved 时补记差额，小于时退回。
	Settle(ctx context.Context, userID, day string, reserved, actual int64) error
	// InstanceUsed 返回实例当天所有账号的总用量，用于展示与判断实例预算。
	InstanceUsed(ctx context.Context, day string) (int64, error)
}

// ErrQuotaExceeded 表示账号当日额度或实例总预算已经用完；代理据此回 429
// quota_exceeded，调用方用 errors.Is 判断。
var ErrQuotaExceeded = errors.New("llmproxy: 托管额度不足")

// quotaLimits 是配额实现接收上限的约定：默认每日额度与实例预算只有配置一处
// 来源，NewHandler 装配时注入给实现，Reserve 用它做原子比较。内存与 PostgreSQL
// 两种实现都实现了这个方法。
type quotaLimits interface {
	SetQuotaLimits(dailyTokens, instanceDailyTokens int64)
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu     sync.Mutex
	used   map[[2]string]int64
	limits map[string]int64

	// dailyTokens 与 instanceTokens 是配置里的默认额度与实例预算，由 NewHandler
	// 装配时注入；小于等于 0 表示不限。
	dailyTokens    int64
	instanceTokens int64
}

func NewMemoryQuota() *MemoryQuota {
	return &MemoryQuota{used: map[[2]string]int64{}, limits: map[string]int64{}}
}

// SetQuotaLimits 注入配置里的默认每日额度与实例预算；由 NewHandler 在装配时调用。
func (m *MemoryQuota) SetQuotaLimits(dailyTokens, instanceDailyTokens int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dailyTokens = dailyTokens
	m.instanceTokens = instanceDailyTokens
}

func (m *MemoryQuota) Used(_ context.Context, userID, day string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.used[[2]string{userID, day}], nil
}

func (m *MemoryQuota) Add(_ context.Context, userID, day string, tokens int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.used[[2]string{userID, day}] += tokens
	return nil
}

// Reserve 在锁里完成比较与扣减，同一账号或同一天的并发请求不会各自读到旧值。
func (m *MemoryQuota) Reserve(_ context.Context, userID, day string, want int64) (int64, error) {
	if want <= 0 {
		return 0, ErrQuotaExceeded
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	key := [2]string{userID, day}
	reserved := want
	if limit, ok := m.accountLimitLocked(userID); ok {
		reserved = min(reserved, limit-m.used[key])
	}
	if m.instanceTokens > 0 {
		reserved = min(reserved, m.instanceTokens-m.instanceUsedLocked(day))
	}
	if reserved <= 0 {
		return 0, ErrQuotaExceeded
	}
	m.used[key] += reserved
	return reserved, nil
}

func (m *MemoryQuota) Settle(_ context.Context, userID, day string, reserved, actual int64) error {
	if actual == reserved {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	key := [2]string{userID, day}
	used := m.used[key] + actual - reserved
	if used < 0 {
		// 预留与结算之间没有别的写路径，负数只可能来自调用方给错参数；归零而不是
		// 留下负用量，查询与上限比较都不会因此失真。
		used = 0
	}
	m.used[key] = used
	return nil
}

func (m *MemoryQuota) InstanceUsed(_ context.Context, day string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.instanceUsedLocked(day), nil
}

// accountLimitLocked 返回账号当天的额度：覆盖值优先，其次配置的默认值；都没有
// 时 ok 为 false，表示不限额度。调用方必须持有 m.mu。
func (m *MemoryQuota) accountLimitLocked(userID string) (int64, bool) {
	if limit, ok := m.limits[userID]; ok {
		return limit, true
	}
	if m.dailyTokens > 0 {
		return m.dailyTokens, true
	}
	return 0, false
}

// instanceUsedLocked 汇总当天所有账号的用量。调用方必须持有 m.mu。
func (m *MemoryQuota) instanceUsedLocked(day string) int64 {
	var total int64
	for key, tokens := range m.used {
		if key[1] == day {
			total += tokens
		}
	}
	return total
}

// SetDailyLimit 调整一个账号的每日额度，供本地联调与测试使用；生产上改
// llm_quota 表。
func (m *MemoryQuota) SetDailyLimit(userID string, tokens int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.limits[userID] = tokens
}

func (m *MemoryQuota) DailyLimit(_ context.Context, userID string) (int64, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	limit, ok := m.limits[userID]
	return limit, ok, nil
}

func (m *MemoryQuota) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k := range m.used {
		if k[0] == userID {
			delete(m.used, k)
		}
	}
	delete(m.limits, userID)
	return nil
}
