// Package cloudpurge 清除一个账号在云端的全部数据（DELETE /v1/cloud）。
//
// 清理是编排而不是新的存储：备份、同步序列与附件各自已有幂等的清空方法，这里
// 按固定顺序调用，最后按账号前缀各清一次遗留对象。步骤全部幂等，中断之后由用户
// 重发 DELETE /v1/cloud 从头再走一遍；从崩溃到重试之间另一台设备推送的内容会在
// 重试时一并清除（审查 9.3 的 V10）。同一个账号同时只允许一次清除、清除期间写
// 请求返回 409，这两件事由 server 包的进程内 cloudOperations 中间件保证，库里
// 不再保存清除标记。
package cloudpurge

import (
	"context"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

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
// 缓存是派生数据，清除云端数据时一并删除；PurgeUser 在同一把账号锁里把代次加一
// 并删行，清除之前发出的嵌入请求因此写不回旧向量（ADR-0037）。删号时这些行随
// 外键级联，所以删号清理仍然用缓存实现的 DeleteUser，不经过这里。
type Embeddings interface {
	PurgeUser(ctx context.Context, userID string) error
}

// Service 编排一次清除。三个数据接口只声明用得到的方法，所以这个包不引用
// backup、blobs、syncsvc。
type Service struct {
	backups    Backups
	syncLog    SyncLog
	blobs      Attachments
	embeddings Embeddings
	objects    objectstore.Store
}

// New 组装清除服务。objects 与备份、附件共用同一份对象存储。
func New(backups Backups, syncLog SyncLog, blobs Attachments, embeddings Embeddings, objects objectstore.Store) *Service {
	return &Service{
		backups:    backups,
		syncLog:    syncLog,
		blobs:      blobs,
		embeddings: embeddings,
		objects:    objects,
	}
}

// Purge 清除账号的云端数据。
//
// 顺序固定：备份、提交序列、附件（索引与字节）、嵌入向量缓存，最后按
// backups/<账号>/ 与 attachments/<账号>/ 前缀各清一次遗留对象。任何一步失败都
// 原样返回错误，由处理器回 500；重试从头执行，各步幂等，所以中断不会留下清了一
// 半的状态。并发的清除请求由进程内的互斥拦住，不走到这里。
func (s *Service) Purge(ctx context.Context, userID string) error {
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
	// 片段。已经发出、正在嵌入的请求由代次拦在写入事务里，清除之后不会再冒出
	// 新行（ADR-0037）。装配没有缓存实现时跳过：没有缓存就没有可清的内容。
	if s.embeddings != nil {
		if err := s.embeddings.PurgeUser(ctx, userID); err != nil {
			return err
		}
	}
	// 备份与附件的清空方法已经按账号清过前缀；这里再清一次，兜住历史遗留的
	// 孤儿对象，例如元数据或索引早已删除、字节还留着的那些。
	if err := s.objects.RemovePrefix(ctx, objectstore.BackupPrefix(userID)); err != nil {
		return err
	}
	return s.objects.RemovePrefix(ctx, objectstore.AttachmentPrefix(userID))
}
