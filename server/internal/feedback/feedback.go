// Package feedback 接收应用内反馈：用户填写的正文与可选的诊断摘要。
//
// 反馈登录与否都能提交，服务端不把反馈绑定到账号，也不解析正文与诊断摘要的
// 内容；保存范围与阅读方式见 ADR-0025 与 server/README。反馈与管理 Issues 是
// 两条路：Issues 留给团队成员按缺陷模板登记，反馈接口收的是用户从应用里发出的
// 原话，两者不自动同步。
package feedback

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

// Item 是一条已经通过校验、等待保存的反馈。
type Item struct {
	// ID 由服务端生成，用来回复与排查，不是客户端的标识。
	ID string
	// Content 是用户填写的正文。
	Content string
	// Contact 是可选的联系邮箱，留空表示用户不要求回复。
	Contact string
	// AppVersion 是客户端版本名，例如 0.2.0-dev+3。
	AppVersion string
	// Platform 是平台，例如 android。
	Platform string
	// Diagnostics 是客户端在本地说明之后附带的诊断摘要，可为空。
	Diagnostics string
	CreatedAt   time.Time
}

// ErrInvalidInput 表示正文为空或某个字段超出长度、联系邮箱不是普通地址。
// 客户端按这个错误提示修改，不需要知道具体是哪一项。
var ErrInvalidInput = errors.New("feedback: invalid input")

// Store 保存反馈。生产实现写 PostgreSQL；反馈不关联账号，删号不影响它。
type Store interface {
	CreateFeedback(ctx context.Context, item Item) error
	// DeleteBefore 删除创建时间早于 before 的反馈，返回删除的行数。保留期清理
	// 每天调用一次，见 Service.PruneLoop。
	DeleteBefore(ctx context.Context, before time.Time) (int64, error)
}

// MemoryStore 把反馈留在进程内存里，用于本地开发与测试。
type MemoryStore struct {
	mu    sync.Mutex
	items []Item
}

func NewMemoryStore() *MemoryStore { return &MemoryStore{} }

func (m *MemoryStore) CreateFeedback(_ context.Context, item Item) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.items = append(m.items, item)
	return nil
}

// DeleteBefore 删除创建时间早于 before 的反馈。内存实现同样保留 CreatedAt，
// 因此清理结果与 PostgreSQL 一致。
func (m *MemoryStore) DeleteBefore(_ context.Context, before time.Time) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	kept := m.items[:0]
	var deleted int64
	for _, item := range m.items {
		if item.CreatedAt.Before(before) {
			deleted++
			continue
		}
		kept = append(kept, item)
	}
	m.items = kept
	return deleted, nil
}

// snapshot 返回已有反馈的副本，供本包测试核对保存结果。读取入口不对外：
// 管理员按 server/README 的说明直接查数据库，不给反馈开列表接口。
func (m *MemoryStore) snapshot() []Item {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Item(nil), m.items...)
}

// newID 生成反馈编号；与备份编号一样用 16 字节随机数的十六进制，服务端不依赖
// 客户端提供标识。
func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
