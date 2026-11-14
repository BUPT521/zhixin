// Package backup stores whole-database snapshots per account (ADR-0008 step 1).
//
// A snapshot is the client's "版本库备份" zip exactly as exported; the server
// checks its size and SHA-256 but never opens it. Restoring re-runs the
// client's existing pre-checks, so this package adds no new restore path.
package backup

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"slices"
	"sync"
	"time"
)

// Meta describes one stored snapshot.
type Meta struct {
	ID            string    `json:"id"`
	SHA256        string    `json:"sha256"`
	Size          int64     `json:"size"`
	SchemaVersion int       `json:"schema_version"`
	DeviceName    string    `json:"device_name"`
	CreatedAt     time.Time `json:"created_at"`
}

var ErrNotFound = errors.New("backup: not found")

// Store keeps snapshot metadata and bytes. The production implementation
// keeps metadata in PostgreSQL and bytes in S3-compatible object storage.
type Store interface {
	// Put stores a snapshot and keeps at most `keep` newest per account.
	Put(ctx context.Context, userID string, m Meta, data io.Reader, keep int) error
	List(ctx context.Context, userID string) ([]Meta, error)
	Open(ctx context.Context, userID, id string) (Meta, io.ReadCloser, error)
	Delete(ctx context.Context, userID, id string) error
	DeleteUser(ctx context.Context, userID string) error
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

type memItem struct {
	meta Meta
	data []byte
}

// MemoryStore is a Store kept in process memory, for development and tests.
type MemoryStore struct {
	mu    sync.Mutex
	items map[string][]memItem // newest last
}

func NewMemoryStore() *MemoryStore { return &MemoryStore{items: map[string][]memItem{}} }

func (m *MemoryStore) Put(_ context.Context, userID string, meta Meta, data io.Reader, keep int) error {
	b, err := io.ReadAll(data)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	list := append(m.items[userID], memItem{meta: meta, data: b})
	if len(list) > keep {
		list = slices.Clone(list[len(list)-keep:])
	}
	m.items[userID] = list
	return nil
}

func (m *MemoryStore) List(_ context.Context, userID string) ([]Meta, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := m.items[userID]
	out := make([]Meta, 0, len(list))
	for i := len(list) - 1; i >= 0; i-- {
		out = append(out, list[i].meta)
	}
	return out, nil
}

func (m *MemoryStore) Open(_ context.Context, userID, id string) (Meta, io.ReadCloser, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, it := range m.items[userID] {
		if it.meta.ID == id {
			return it.meta, io.NopCloser(bytes.NewReader(it.data)), nil
		}
	}
	return Meta{}, nil, ErrNotFound
}

func (m *MemoryStore) Delete(_ context.Context, userID, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	list := m.items[userID]
	for i, it := range list {
		if it.meta.ID == id {
			m.items[userID] = slices.Delete(slices.Clone(list), i, i+1)
			return nil
		}
	}
	return ErrNotFound
}

func (m *MemoryStore) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.items, userID)
	return nil
}
