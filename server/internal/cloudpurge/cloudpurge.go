// Package cloudpurge 清除一个账号在云端的全部数据（DELETE /v1/cloud）。
//
// 清理是编排而不是新的存储：备份、同步序列与附件各自已有幂等的清空方法，这里
// 按固定顺序调用，最后按账号前缀各清一次遗留对象。清除开始先写一条标记，结束时
// 删掉：标记让同一个账号同时只有一次清除，也让清除期间各写处理器返回 409；
// 中途失败时标记保留，客户端退避后重试会从头再走一遍，每一步都幂等。
package cloudpurge

import (
	"context"
	"errors"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// ErrPurging 表示这个账号的云端数据正在清除。装配给各处理器的 gate 返回它时，
// 处理器回 409 conflict 并且不写数据。
var ErrPurging = errors.New("cloudpurge: 云端数据正在清除")

// ErrInProgress 表示另一个清除请求已经开始且还没有结束；处理器同样回 409，
// 客户端稍后重试。
var ErrInProgress = errors.New("cloudpurge: 清除已经进行中")

// StaleAfter 是清除标记的有效期。超过它的标记视为上次中断留下的：新的清除
// 请求接管重做，写处理器也不再因为这条旧标记拒绝请求。
const StaleAfter = 10 * time.Minute

// Store 保存进行中的清除标记。内存实现用于本地联调与测试，PostgreSQL 实现
// 见 internal/store/pg。
type Store interface {
	// PurgeStartedAt 返回标记的时间；没有标记时 ok 为 false。
	PurgeStartedAt(ctx context.Context, userID string) (startedAt time.Time, ok bool, err error)
	// ClaimPurge 原子地取得清除权：没有标记，或标记早于 staleBefore 时写入
	// now 并返回 true；标记还新时返回 false 且不修改。
	ClaimPurge(ctx context.Context, userID string, now, staleBefore time.Time) (bool, error)
	// EndPurge 删除标记。
	EndPurge(ctx context.Context, userID string) error
}

// Backups 是清除备份需要的能力，由 backup.Store 满足。
type Backups interface {
	DeleteAll(ctx context.Context, userID string) error
}

// SyncLog 是清空提交序列需要的能力，由 syncsvc.Store 满足。
type SyncLog interface {
	Reset(ctx context.Context, userID string) error
}

// Attachments 是清空附件与索引需要的能力，由 blobs.Store 满足。
type Attachments interface {
	DeleteUser(ctx context.Context, userID string) error
}

// Embeddings 是清空嵌入向量缓存需要的能力，由 llmproxy.EmbeddingCache 满足。
// 缓存是派生数据，清除云端数据时一并删除；删号时这些行随外键级联，也要在
// 删除账号行之前清一遍，重试才能从头再走。
type Embeddings interface {
	DeleteUser(ctx context.Context, userID string) error
}

// Service 编排一次清除。三个数据接口只声明用得到的方法，所以这个包不引用
// backup、blobs、syncsvc，处理器可以反过来引用这里的 ErrPurging 而不形成循环。
type Service struct {
	store      Store
	backups    Backups
	syncLog    SyncLog
	blobs      Attachments
	embeddings Embeddings
	objects    objectstore.Store
	now        func() time.Time
}

// New 组装清除服务。objects 与备份、附件共用同一份对象存储；时钟只在测试里
// 替换，用来模拟 10 分钟的标记过期。
func New(store Store, backups Backups, syncLog SyncLog, blobs Attachments, embeddings Embeddings, objects objectstore.Store) *Service {
	return &Service{
		store:      store,
		backups:    backups,
		syncLog:    syncLog,
		blobs:      blobs,
		embeddings: embeddings,
		objects:    objects,
		now:        time.Now,
	}
}

// Purge 清除账号的云端数据。
//
// 顺序固定：备份、提交序列、附件（索引与字节）、嵌入向量缓存，最后按
// backups/<账号>/ 与 attachments/<账号>/ 前缀各清一次遗留对象。任何一步失败都
// 保留标记并原样返回错误，由处理器回 500；重试从头执行，各步幂等，所以中断不会
// 留下清了一半的状态。标记还新时返回 ErrInProgress（409），超过 StaleAfter 则
// 接管重做。
func (s *Service) Purge(ctx context.Context, userID string) error {
	now := s.now().UTC()
	claimed, err := s.store.ClaimPurge(ctx, userID, now, now.Add(-StaleAfter))
	if err != nil {
		return err
	}
	if !claimed {
		return ErrInProgress
	}
	if err := s.backups.DeleteAll(ctx, userID); err != nil {
		return err
	}
	if err := s.syncLog.Reset(ctx, userID); err != nil {
		return err
	}
	if err := s.blobs.DeleteUser(ctx, userID); err != nil {
		return err
	}
	// 向量缓存是派生数据，清除之后客户端下次索引刷新重新查缓存、补算未命中的
	// 片段。清除期间的写入由各处理器调 Gate 拦住，嵌入请求带缓存头时也不写。
	// 装配没有缓存实现时跳过：没有缓存就没有可清的内容。
	if s.embeddings != nil {
		if err := s.embeddings.DeleteUser(ctx, userID); err != nil {
			return err
		}
	}
	// 备份与附件的清空方法已经按账号清过前缀；这里再清一次，兜住历史遗留的
	// 孤儿对象，例如元数据或索引早已删除、字节还留着的那些。
	if err := s.objects.RemovePrefix(ctx, objectstore.BackupPrefix(userID)); err != nil {
		return err
	}
	if err := s.objects.RemovePrefix(ctx, objectstore.AttachmentPrefix(userID)); err != nil {
		return err
	}
	return s.store.EndPurge(ctx, userID)
}

// Gate 供各写处理器在写数据之前调用：标记是新的就返回 ErrPurging，让这次
// 写入回 409；没有标记或标记已经过期时返回 nil，写入照常。
//
// 过期标记不拦写入是刻意的：上次清除中断之后没有人重试时，账号不应该被一条
// 旧标记永久锁住；下一次清除请求会接管并刷新标记的时间。
func (s *Service) Gate(ctx context.Context, userID string) error {
	startedAt, ok, err := s.store.PurgeStartedAt(ctx, userID)
	if err != nil {
		return err
	}
	if !ok || s.now().UTC().Sub(startedAt) >= StaleAfter {
		return nil
	}
	return ErrPurging
}
