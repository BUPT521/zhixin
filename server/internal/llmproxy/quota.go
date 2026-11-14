package llmproxy

import (
	"context"
	"sync"
)

// Quota tracks tokens used per account per local day. The day key is a
// YYYY-MM-DD string in the configured time zone (ZHIXIN_TIMEZONE).
type Quota interface {
	Used(ctx context.Context, userID, day string) (int64, error)
	Add(ctx context.Context, userID, day string, tokens int64) error
	DeleteUser(ctx context.Context, userID string) error
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu   sync.Mutex
	used map[[2]string]int64
}

func NewMemoryQuota() *MemoryQuota { return &MemoryQuota{used: map[[2]string]int64{}} }

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

func (m *MemoryQuota) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k := range m.used {
		if k[0] == userID {
			delete(m.used, k)
		}
	}
	return nil
}
