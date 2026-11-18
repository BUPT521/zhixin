package pg

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/jackc/pgx/v5"

	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// BlobStore 是 blobs.Store 的 PostgreSQL 实现，与 Store 共用连接池与对象存储。
//
// 单独一个类型而不是把方法挂在 Store 上，有两个原因。第一，Store 的
// DeleteUser 是 auth.Store 的语义（删账号行，附件靠外键级联），与 blobs.Store
// 的 DeleteUser（清附件字节与索引、保留账号）同名不同义。第二，备份的 Open
// 返回 (backup.Meta, io.ReadCloser, error)，附件的 Open 返回
// (io.ReadCloser, int64, error)，签名在同一个类型上无法共存。
type BlobStore struct {
	store *Store
}

// NewBlobStore 建立附件存储；它不访问网络，连通性由 Store 的 Ping 负责。
func NewBlobStore(store *Store) *BlobStore { return &BlobStore{store: store} }

// Stat 返回附件字节数。存在与否以对象存储为准：历史版本只写了字节、还没回填
// 索引的附件因此仍然可读；回填命令负责把它们的配额补进 attachment 表。
func (b *BlobStore) Stat(ctx context.Context, userID, sha string) (int64, error) {
	info, err := b.store.objects.Stat(ctx, objectstore.AttachmentKey(userID, sha))
	if err != nil {
		return 0, mapObjectErr(err)
	}
	return info.Size, nil
}

func (b *BlobStore) Open(ctx context.Context, userID, sha string) (io.ReadCloser, int64, error) {
	rc, info, err := b.store.objects.Open(ctx, objectstore.AttachmentKey(userID, sha))
	if err != nil {
		return nil, 0, mapObjectErr(err)
	}
	return rc, info.Size, nil
}

// Save 只写字节；索引行由 Reserve 事先建立，失败时调用方用 Release 回滚。
func (b *BlobStore) Save(ctx context.Context, userID, sha string, size int64, data io.Reader) error {
	return b.store.objects.Put(ctx, objectstore.AttachmentKey(userID, sha), data, objectstore.Info{
		Size:        size,
		ContentType: "application/octet-stream",
	})
}

// Reserve 在一个事务里锁住账号行，再求和与写入索引。
//
// 锁账号行是并发的关键：同一账号的两次上传在这里排队，后一个看到的已用量包含
// 前一个刚预留的字节，所以两个请求不会各自按旧的总量通过检查。同一 sha 已有
// 索引行时不重复计数，直接返回当前已用量。
func (b *BlobStore) Reserve(ctx context.Context, userID, sha string, size, limit int64) (int64, error) {
	tx, err := b.store.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := b.store.q.WithTx(tx)

	if _, err := q.LockUser(ctx, userID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return 0, fmt.Errorf("pg: 账号 %s 不存在，无法预留附件配额", userID)
		}
		return 0, err
	}

	if _, err := q.AttachmentSize(ctx, db.AttachmentSizeParams{UserID: userID, Sha256: sha}); err == nil {
		used, err := q.SumAttachmentBytes(ctx, userID)
		if err != nil {
			return 0, err
		}
		if err := tx.Commit(ctx); err != nil {
			return 0, err
		}
		return used, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return 0, err
	}

	used, err := q.SumAttachmentBytes(ctx, userID)
	if err != nil {
		return 0, err
	}
	if limit > 0 && used+size > limit {
		// 不提交：事务回滚，索引与已用量都没有变化。
		return used, &blobs.StorageFullError{Used: used, Limit: limit}
	}
	if _, err := q.InsertAttachment(ctx, db.InsertAttachmentParams{
		UserID: userID,
		Sha256: sha,
		Size:   size,
	}); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return used + size, nil
}

// Release 撤销一次预留。字节已经在对象存储里时不删索引行：同一内容的并发上传
// 可能已经把字节写成功，这一次失败的是本次写入；只有在字节确实不存在时才删。
func (b *BlobStore) Release(ctx context.Context, userID, sha string, _ int64) error {
	if _, err := b.store.objects.Stat(ctx, objectstore.AttachmentKey(userID, sha)); err == nil {
		return nil
	} else if !errors.Is(err, objectstore.ErrNotFound) {
		return err
	}
	_, err := b.store.q.DeleteAttachment(ctx, db.DeleteAttachmentParams{UserID: userID, Sha256: sha})
	return err
}

// Used 返回账号已用的附件总字节数；空账号是 0。
func (b *BlobStore) Used(ctx context.Context, userID string) (int64, error) {
	return b.store.q.SumAttachmentBytes(ctx, userID)
}

// DeleteUser 清掉账号的附件索引与对象存储里的字节，账号行本身不动。先删索引再
// 按前缀清字节：两步都幂等，中断之后重试即可收敛；任一步失败都原样返回。
func (b *BlobStore) DeleteUser(ctx context.Context, userID string) error {
	if err := b.store.q.DeleteAttachments(ctx, userID); err != nil {
		return err
	}
	return b.store.objects.RemovePrefix(ctx, objectstore.AttachmentPrefix(userID))
}

// BackfillAttachment 把对象存储里的一个附件补进索引，返回是否新增了一行。
// 回填命令按 attachments/ 前缀遍历对象后调用它，重复执行是安全的。
func (b *BlobStore) BackfillAttachment(ctx context.Context, userID, sha string, size int64) (bool, error) {
	inserted, err := b.store.q.InsertAttachment(ctx, db.InsertAttachmentParams{
		UserID: userID,
		Sha256: sha,
		Size:   size,
	})
	if err != nil {
		return false, err
	}
	return inserted > 0, nil
}

// ListAttachments 按从新到旧列出账号的索引行，供核对与排查使用。
func (b *BlobStore) ListAttachments(ctx context.Context, userID string) ([]db.ListAttachmentsRow, error) {
	return b.store.q.ListAttachments(ctx, userID)
}

func mapObjectErr(err error) error {
	if errors.Is(err, objectstore.ErrNotFound) {
		return blobs.ErrNotFound
	}
	return err
}
