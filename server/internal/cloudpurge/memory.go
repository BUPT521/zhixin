package cloudpurge

import (
	"context"
	"sync"
	"time"
)

// MemoryStore 把清除标记留在进程内存里，只用于没有数据库的联调与测试。
type MemoryStore struct {
	mu    sync.Mutex
	marks map[string]time.Time
}

// NewMemoryStore 返回一个空的标记存储。
func NewMemoryStore() *MemoryStore { return &MemoryStore{marks: map[string]time.Time{}} }

func (m *MemoryStore) PurgeStartedAt(_ context.Context, userID string) (time.Time, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	started, ok := m.marks[userID]
	return started, ok, nil
}

// ClaimPurge 的判定与 SQL 实现一致：标记早于 staleBefore 才算过期可覆盖，
// 正好等于 staleBefore 的标记仍然算新。
func (m *MemoryStore) ClaimPurge(_ context.Context, userID string, now, staleBefore time.Time) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if started, ok := m.marks[userID]; ok && !started.Before(staleBefore) {
		return false, nil
	}
	m.marks[userID] = now
	return true, nil
}

func (m *MemoryStore) EndPurge(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.marks, userID)
	return nil
}
