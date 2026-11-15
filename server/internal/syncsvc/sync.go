// Package syncsvc keeps one linear commit log per account (ADR-0008 step 2).
//
// The server does not merge. A push must be based on the current server head;
// otherwise it is rejected with 409 and the client pulls, applies the remote
// commits locally as new local commits (so undo keeps working), and pushes
// again. Each commit carries the client's request_id so a retried push is a
// no-op. Field-level conflict handling stays on the client and is still to be
// decided after a two-device walkthrough.
package syncsvc

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// Change 与 Commit 直接使用契约生成的类型，服务端不再维护手写镜像。
//
// Change 的 before/after 在契约里声明为 json.RawMessage（x-go-type），行内容
// 原样转发：既不经 interface{} 解码，也不会把大整数变成 float64 而改变数值。
type (
	Change = api.Change
	Commit = api.Commit
)

var (
	// ErrHeadMoved means the push was not based on the current server head.
	ErrHeadMoved = errors.New("sync: server head moved")
	// ErrInvalid means a commit failed validation.
	ErrInvalid = errors.New("sync: invalid commit")
)

// Store is the per-account commit log.
type Store interface {
	// Head returns the last assigned sequence number, 0 when empty.
	Head(ctx context.Context, userID string) (int64, error)
	// Append atomically checks base == head and appends commits whose
	// request_id is new. It returns the resulting head.
	Append(ctx context.Context, userID string, base int64, commits []Commit) (int64, error)
	// After returns up to limit commits with seq > after, in order.
	After(ctx context.Context, userID string, after int64, limit int) ([]Commit, error)
}

// MemoryStore is a Store kept in process memory.
type MemoryStore struct {
	mu   sync.Mutex
	logs map[string][]Commit
	now  func() time.Time
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{logs: map[string][]Commit{}, now: time.Now}
}

func (m *MemoryStore) Head(_ context.Context, userID string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return int64(len(m.logs[userID])), nil
}

// PlanAppend filters request IDs the account has already stored and checks that
// a non-empty batch is based on the current head. Both the in-memory and the
// PostgreSQL store call this, so the rules live in one place.
func PlanAppend(
	head, base int64,
	commits []Commit,
	seen map[string]bool,
) (fresh []Commit, newHead int64, err error) {
	for _, c := range commits {
		if seen[c.RequestId] {
			continue
		}
		seen[c.RequestId] = true
		fresh = append(fresh, c)
	}
	// A fully replayed push succeeds whatever its base: the client simply did
	// not see the previous response.
	if len(fresh) == 0 {
		return nil, head, nil
	}
	if base != head {
		return nil, head, ErrHeadMoved
	}
	return fresh, head + int64(len(fresh)), nil
}

func (m *MemoryStore) Append(_ context.Context, userID string, base int64, commits []Commit) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	log := m.logs[userID]
	seen := make(map[string]bool, len(log))
	for _, c := range log {
		seen[c.RequestId] = true
	}
	fresh, newHead, err := PlanAppend(int64(len(log)), base, commits, seen)
	if err != nil {
		return int64(len(log)), err
	}
	if len(fresh) == 0 {
		return int64(len(log)), nil
	}
	received := m.now()
	for _, c := range fresh {
		seq := int64(len(log)) + 1
		c.Seq = &seq
		c.ReceivedAt = &received
		log = append(log, c)
	}
	m.logs[userID] = log
	return newHead, nil
}

func (m *MemoryStore) After(_ context.Context, userID string, after int64, limit int) ([]Commit, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	log := m.logs[userID]
	if after < 0 {
		after = 0
	}
	if after >= int64(len(log)) {
		return nil, nil
	}
	end := min(after+int64(limit), int64(len(log)))
	return append([]Commit(nil), log[after:end]...), nil
}

func (m *MemoryStore) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.logs, userID)
	return nil
}

// Validate checks the shape of a commit, not its business meaning: the server
// never interprets learning content. Op and Actor are checked through the
// generated enum validators, so the contract stays the only value list.
func Validate(c Commit, schemaVersion int) error {
	switch {
	case c.RequestId == "" || len(c.RequestId) > 64,
		c.DeviceId == "" || len(c.DeviceId) > 64,
		c.SchemaVersion != schemaVersion,
		!c.Actor.Valid(),
		c.Action == "",
		len(c.Changes) == 0:
		return ErrInvalid
	}
	for _, ch := range c.Changes {
		if ch.Table == "" || ch.RowKey == "" || !ch.Op.Valid() {
			return ErrInvalid
		}
		needBefore := ch.Op == api.Update || ch.Op == api.Delete
		needAfter := ch.Op == api.Insert || ch.Op == api.Update
		if (needBefore && ch.Before == nil) || (needAfter && ch.After == nil) {
			return ErrInvalid
		}
	}
	return nil
}
