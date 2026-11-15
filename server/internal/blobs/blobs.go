// Package blobs 保存附件的字节，按账号与内容的 SHA-256 寻址（/v1/blobs）。
//
// 服务端只核对哈希，不解析内容；同一个账号下相同内容只存一份。字节落在
// objectstore 里，键是 attachments/<账号>/<sha256>（ADR-0016）。
package blobs

import (
	"context"
	"errors"
	"io"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// ErrNotFound 表示账号名下没有这个附件。
var ErrNotFound = errors.New("blobs: 附件不存在")

// Store 保存并读取附件；附件按内容寻址，写入相同内容的结果相同。
type Store interface {
	// Stat 返回字节数；不存在时返回 ErrNotFound。
	Stat(ctx context.Context, userID, sha string) (int64, error)
	// Open 返回内容与字节数；不存在时返回 ErrNotFound。
	Open(ctx context.Context, userID, sha string) (io.ReadCloser, int64, error)
	// Save 写入 size 字节；调用方已经核对过内容与 sha 一致。
	Save(ctx context.Context, userID, sha string, size int64, data io.Reader) error
	// DeleteUser 删除账号名下的全部附件。
	DeleteUser(ctx context.Context, userID string) error
}

// ObjectStore 是生产实现：附件键放在共享的对象存储里。
type ObjectStore struct {
	objects objectstore.Store
}

// NewStore 用给定的对象存储实现附件存储。
func NewStore(objects objectstore.Store) *ObjectStore { return &ObjectStore{objects: objects} }

func (o *ObjectStore) Stat(ctx context.Context, userID, sha string) (int64, error) {
	info, err := o.objects.Stat(ctx, objectstore.AttachmentKey(userID, sha))
	if err != nil {
		return 0, mapErr(err)
	}
	return info.Size, nil
}

func (o *ObjectStore) Open(ctx context.Context, userID, sha string) (io.ReadCloser, int64, error) {
	rc, info, err := o.objects.Open(ctx, objectstore.AttachmentKey(userID, sha))
	if err != nil {
		return nil, 0, mapErr(err)
	}
	return rc, info.Size, nil
}

func (o *ObjectStore) Save(ctx context.Context, userID, sha string, size int64, data io.Reader) error {
	return o.objects.Put(ctx, objectstore.AttachmentKey(userID, sha), data, objectstore.Info{
		Size:        size,
		ContentType: "application/octet-stream",
	})
}

func (o *ObjectStore) DeleteUser(ctx context.Context, userID string) error {
	return o.objects.RemovePrefix(ctx, objectstore.AttachmentPrefix(userID))
}

func mapErr(err error) error {
	if errors.Is(err, objectstore.ErrNotFound) {
		return ErrNotFound
	}
	return err
}
