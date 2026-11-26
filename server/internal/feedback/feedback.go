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
	"slices"
	"strings"
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

var ErrCapacity = errors.New("feedback: retained feedback limit reached")

// ErrNotFound 表示按编号找不到这条反馈，管理后台据此返回 404。
var ErrNotFound = errors.New("feedback: not found")

const MaxRetainedItems = 10_000

// ListItem 是管理后台列表里的一条反馈。诊断摘要至多 64 KiB，列表不返回它，
// 只标出有没有；读取单条时再取全文。
type ListItem struct {
	ID             string
	Content        string
	Contact        string
	AppVersion     string
	Platform       string
	HasDiagnostics bool
	CreatedAt      time.Time
}

// Store 保存反馈。生产实现写 PostgreSQL；反馈不关联账号，删号不影响它。
type Store interface {
	CreateFeedback(ctx context.Context, item Item) error
	// DeleteBefore 删除创建时间早于 before 的反馈，返回删除的行数。保留期清理
	// 每天调用一次，见 Service.PruneLoop。
	DeleteBefore(ctx context.Context, before time.Time) (int64, error)
}

// AdminStore 是管理后台查看与删除反馈需要的存储子集。读取按提交时间倒序，
// query 匹配编号、正文、联系邮箱、版本与平台；删除一条不存在的反馈返回
// ErrNotFound，让管理接口回 404 而不是悄悄成功。
type AdminStore interface {
	ListFeedback(ctx context.Context, query string, limit, offset int) ([]ListItem, int, error)
	FeedbackByID(ctx context.Context, id string) (Item, error)
	DeleteFeedback(ctx context.Context, id string) error
}

// Repository 是反馈的完整存储：公开提交与保留期清理用 Store，管理后台用
// AdminStore。内存实现与 PostgreSQL 实现都满足。
type Repository interface {
	Store
	AdminStore
}

// MemoryStore 把反馈留在进程内存里，用于本地开发与测试。
type MemoryStore struct {
	mu    sync.Mutex
	items []Item
}

func NewMemoryStore() *MemoryStore { return &MemoryStore{} }

var _ Repository = (*MemoryStore)(nil)

func (m *MemoryStore) CreateFeedback(_ context.Context, item Item) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.items) >= MaxRetainedItems {
		return ErrCapacity
	}
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
	clear(m.items[len(kept):])
	m.items = kept
	return deleted, nil
}

// ListFeedback 按提交时间倒序返回一页反馈，并给出匹配的总条数，口径与
// PostgreSQL 实现一致：query 转小写之后在编号、正文、联系邮箱、版本与平台里
// 找子串，空值列出全部。
func (m *MemoryStore) ListFeedback(_ context.Context, query string, limit, offset int) ([]ListItem, int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	needle := strings.ToLower(strings.TrimSpace(query))
	matched := make([]ListItem, 0, len(m.items))
	for _, item := range m.items {
		if !feedbackMatches(item, needle) {
			continue
		}
		matched = append(matched, ListItem{
			ID:             item.ID,
			Content:        item.Content,
			Contact:        item.Contact,
			AppVersion:     item.AppVersion,
			Platform:       item.Platform,
			HasDiagnostics: item.Diagnostics != "",
			CreatedAt:      item.CreatedAt,
		})
	}
	slices.SortFunc(matched, func(a, b ListItem) int {
		if !a.CreatedAt.Equal(b.CreatedAt) {
			if a.CreatedAt.After(b.CreatedAt) {
				return -1
			}
			return 1
		}
		return strings.Compare(a.ID, b.ID)
	})
	total := len(matched)
	if offset >= total {
		return []ListItem{}, total, nil
	}
	end := min(offset+limit, total)
	return matched[offset:end], total, nil
}

// FeedbackByID 取一条反馈的全文，包括诊断摘要。
func (m *MemoryStore) FeedbackByID(_ context.Context, id string) (Item, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, item := range m.items {
		if item.ID == id {
			return item, nil
		}
	}
	return Item{}, ErrNotFound
}

// DeleteFeedback 删除一条反馈，找不到时返回 ErrNotFound。
func (m *MemoryStore) DeleteFeedback(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, item := range m.items {
		if item.ID != id {
			continue
		}
		m.items = append(m.items[:i], m.items[i+1:]...)
		return nil
	}
	return ErrNotFound
}

// feedbackMatches 是内存实现的关键字匹配，字段范围与 queries/feedback.sql 的
// CountFeedback、ListFeedback 相同。
func feedbackMatches(item Item, needle string) bool {
	if needle == "" {
		return true
	}
	for _, field := range []string{item.ID, item.Content, item.Contact, item.AppVersion, item.Platform} {
		if strings.Contains(strings.ToLower(field), needle) {
			return true
		}
	}
	return false
}

// snapshot 返回已有反馈的副本，供本包测试核对保存结果；管理后台的读取走
// ListFeedback 与 FeedbackByID。
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
