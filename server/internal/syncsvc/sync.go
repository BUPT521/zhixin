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
	"encoding/json"
	"errors"
	"sync"
	"time"
)

// Change mirrors one row of the client's revision_change table (docs/01 §7).
type Change struct {
	Table  string          `json:"table"`
	RowKey string          `json:"row_key"`
	Op     string          `json:"op"`
	Before json.RawMessage `json:"before,omitempty"`
	After  json.RawMessage `json:"after,omitempty"`
}

// Commit is one business write. Seq and ReceivedAt are assigned by the server.
type Commit struct {
	Seq           int64     `json:"seq"`
	RequestID     string    `json:"request_id"`
	DeviceID      string    `json:"device_id"`
	SchemaVersion int       `json:"schema_version"`
	Actor         string    `json:"actor"`
	Action        string    `json:"action"`
	CreatedAt     string    `json:"created_at"`
	ReceivedAt    time.Time `json:"received_at"`
	Changes       []Change  `json:"changes"`
}

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
	// DeleteUser removes the whole log of an account.
	DeleteUser(ctx context.Context, userID string) error
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

func (m *MemoryStore) Append(_ context.Context, userID string, base int64, commits []Commit) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	log := m.logs[userID]
	seen := make(map[string]bool, len(log))
	for _, c := range log {
		seen[c.RequestID] = true
	}
	var fresh []Commit
	for _, c := range commits {
		if !seen[c.RequestID] {
			seen[c.RequestID] = true
			fresh = append(fresh, c)
		}
	}
	// A fully replayed push succeeds whatever its base: the client simply
	// did not see the previous response.
	if len(fresh) == 0 {
		return int64(len(log)), nil
	}
	if base != int64(len(log)) {
		return int64(len(log)), ErrHeadMoved
	}
	now := m.now()
	for _, c := range fresh {
		c.Seq = int64(len(log)) + 1
		c.ReceivedAt = now
		log = append(log, c)
	}
	m.logs[userID] = log
	return int64(len(log)), nil
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

var validOps = map[string]bool{"insert": true, "update": true, "delete": true}
var validActors = map[string]bool{"user": true, "ai": true, "system": true}

// Validate checks the shape of a commit, not its business meaning: the server
// never interprets learning content.
func Validate(c Commit, schemaVersion int) error {
	switch {
	case c.RequestID == "" || len(c.RequestID) > 64,
		c.DeviceID == "" || len(c.DeviceID) > 64,
		c.SchemaVersion != schemaVersion,
		!validActors[c.Actor],
		c.Action == "",
		len(c.Changes) == 0:
		return ErrInvalid
	}
	for _, ch := range c.Changes {
		if ch.Table == "" || ch.RowKey == "" || !validOps[ch.Op] {
			return ErrInvalid
		}
		needBefore := ch.Op == "update" || ch.Op == "delete"
		needAfter := ch.Op == "insert" || ch.Op == "update"
		if (needBefore && ch.Before == nil) || (needAfter && ch.After == nil) {
			return ErrInvalid
		}
	}
	return nil
}
