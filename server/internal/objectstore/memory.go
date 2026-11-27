package objectstore

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"
)

// memObject 是一个内存对象：字节与写入时间。
type memObject struct {
	data    []byte
	modTime time.Time
}

// Memory 把对象留在进程内存里，只用于没有数据库的联调与测试，退出即丢。
type Memory struct {
	mu    sync.RWMutex
	items map[string]memObject
}

// NewMemory 返回一个空的内存实现。
func NewMemory() *Memory { return &Memory{items: map[string]memObject{}} }

func (m *Memory) Put(ctx context.Context, key string, data io.Reader, info Info) error {
	return m.PutAt(ctx, key, data, info, time.Now())
}

// PutAt 写入对象并把修改时间设成 at，供测试构造“早先写入”的遗留对象。正常
// 写入用 Put，修改时间是写入的那一刻；对账按这个时间判断宽限期。
func (m *Memory) PutAt(_ context.Context, key string, data io.Reader, info Info, at time.Time) error {
	if key == "" {
		return errors.New("objectstore: 键为空")
	}
	b, err := io.ReadAll(data)
	if err != nil {
		return err
	}
	if int64(len(b)) != info.Size {
		return fmt.Errorf("objectstore: 实际写入 %d 字节，与声明的 %d 不符", len(b), info.Size)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items[key] = memObject{data: b, modTime: at}
	return nil
}

func (m *Memory) Open(_ context.Context, key string) (io.ReadCloser, Info, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	it, ok := m.items[key]
	if !ok {
		return nil, Info{}, ErrNotFound
	}
	return io.NopCloser(bytes.NewReader(it.data)), Info{Size: int64(len(it.data))}, nil
}

func (m *Memory) Stat(_ context.Context, key string) (Info, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	it, ok := m.items[key]
	if !ok {
		return Info{}, ErrNotFound
	}
	return Info{Size: int64(len(it.data))}, nil
}

func (m *Memory) Remove(_ context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.items, key)
	return nil
}

func (m *Memory) RemovePrefix(_ context.Context, prefix string) error {
	if prefix == "" {
		return errors.New("objectstore: 拒绝删除空前缀")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for key := range m.items {
		if strings.HasPrefix(key, prefix) {
			delete(m.items, key)
		}
	}
	return nil
}

// List 按前缀列出对象，按键排序，备份对账与测试的列举结果因此稳定。
func (m *Memory) List(_ context.Context, prefix string) ([]Object, error) {
	if prefix == "" {
		return nil, errors.New("objectstore: 拒绝列出空前缀")
	}
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]Object, 0, len(m.items))
	for key, it := range m.items {
		if strings.HasPrefix(key, prefix) {
			out = append(out, Object{Key: key, ModTime: it.modTime})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

func (m *Memory) Ping(context.Context) error { return nil }
