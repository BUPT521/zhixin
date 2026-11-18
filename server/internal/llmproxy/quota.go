package llmproxy

import (
	"context"
	"sync"
)

// Quota tracks tokens used per account, per local day and per kind of model.
// The day key is a YYYY-MM-DD string in the configured time zone
// (ZHIXIN_TIMEZONE). Chat and embedding budgets are separate: a full index
// rebuild spends far more embedding tokens than a day of chatting, and must
// not use up the chat budget.
//
// DailyLimit 读取按账号调整过的每日额度；没有覆盖值时返回 ok=false，由代理用
// ZHIXIN_LLM_DAILY_TOKENS 或 ZHIXIN_LLM_EMBEDDING_DAILY_TOKENS。管理员在
// llm_quota 表里调整，见 server/README。
type Quota interface {
	Used(ctx context.Context, userID, day string, kind Kind) (int64, error)
	Add(ctx context.Context, userID, day string, kind Kind, tokens int64) error
	DailyLimit(ctx context.Context, userID string, kind Kind) (int64, bool, error)
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu     sync.Mutex
	used   map[[3]string]int64
	limits map[[2]string]int64
}

func NewMemoryQuota() *MemoryQuota {
	return &MemoryQuota{used: map[[3]string]int64{}, limits: map[[2]string]int64{}}
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

// SetDailyLimit 调整一个账号的聊天每日额度，供本地联调与测试使用；生产上改
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

func (m *MemoryQuota) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k := range m.used {
		if k[0] == userID {
			delete(m.used, k)
		}
	}
	for k := range m.limits {
		if k[0] == userID {
			delete(m.limits, k)
		}
	}
	return nil
}
