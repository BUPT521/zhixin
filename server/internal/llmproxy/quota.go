package llmproxy

import (
	"context"
	"sync"
)

// Quota tracks tokens used per account per local day. The day key is a
// YYYY-MM-DD string in the configured time zone (ZHIXIN_TIMEZONE).
//
// DailyLimit 读取按账号调整过的每日额度；没有覆盖行时返回 ok=false，由代理用
// ZHIXIN_LLM_DAILY_TOKENS。管理员在 llm_quota 表里调整，见 server/README。
type Quota interface {
	Used(ctx context.Context, userID, day string) (int64, error)
	Add(ctx context.Context, userID, day string, tokens int64) error
	DailyLimit(ctx context.Context, userID string) (int64, bool, error)
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu     sync.Mutex
	used   map[[2]string]int64
	limits map[string]int64
}

func NewMemoryQuota() *MemoryQuota {
	return &MemoryQuota{used: map[[2]string]int64{}, limits: map[string]int64{}}
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
