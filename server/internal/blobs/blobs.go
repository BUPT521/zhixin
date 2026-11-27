// Package blobs 保存附件的字节，按账号与内容的 SHA-256 寻址（/v1/blobs）。
//
// 服务端只核对哈希，不解析内容；同一个账号下相同内容只存一份。字节落在
// objectstore 里，键是 attachments/<账号>/<sha256>（ADR-0016）。账号总量配额
// 由 attachment 索引维护：存储层在写入字节之前先原子预留字节数，所以并发的
// 两次上传不会各自按旧的已用量通过检查。
package blobs

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// ErrNotFound 表示账号名下没有这个附件。
var ErrNotFound = errors.New("blobs: 附件不存在")

// ErrStorageFull 是账号附件总量超限的哨兵。存储层返回 *StorageFullError，
// 它同时满足 errors.Is(err, ErrStorageFull)；调用方要读已用量与上限时用
// errors.As 取具体类型。
var ErrStorageFull = errors.New("blobs: 账号附件总量超过上限")

// StorageFullError 报告一次预留会超过账号总量上限，带上当前已用量与上限：
// 处理器在 413 的 extra 里给出 used_bytes 与 limit_bytes（契约如此定义）。
type StorageFullError struct {
	Used  int64
	Limit int64
}

func (e *StorageFullError) Error() string {
	return fmt.Sprintf("blobs: 账号附件已用 %d 字节，上限 %d 字节", e.Used, e.Limit)
}

// Is 让 errors.Is(err, ErrStorageFull) 成立，调用方不必只认具体类型。
func (e *StorageFullError) Is(target error) bool { return target == ErrStorageFull }

// Store 保存并读取附件；附件按内容寻址，写入相同内容的结果相同。
type Store interface {
	// Stat 返回字节数；不存在时返回 ErrNotFound。
	Stat(ctx context.Context, userID, sha string) (int64, error)
	// Open 返回内容与字节数；不存在时返回 ErrNotFound。
	Open(ctx context.Context, userID, sha string) (io.ReadCloser, int64, error)
	// Save 写入 size 字节；调用方已经核对过内容与 sha 一致，并已用 Reserve
	// 预留过配额。保存失败时调用方会用 Release 回滚。
	Save(ctx context.Context, userID, sha string, size int64, data io.Reader) error
	// Reserve 原子预留 size 字节的账号配额，返回预留后的已用量。同一账号
	// 已有这个 sha 时不重复计数，直接返回当前已用量；超过 limit 时返回
	// *StorageFullError 且不改变任何状态。
	Reserve(ctx context.Context, userID, sha string, size, limit int64) (int64, error)
	// Release 撤销一次预留。字节已经在存储里时保留索引，因为同一内容的并发
	// 上传可能已经写成功；只有字节确实不存在时才删掉索引行。
	Release(ctx context.Context, userID, sha string, size int64) error
	// Used 返回账号已用的附件总字节数；空账号是 0。
	Used(ctx context.Context, userID string) (int64, error)
	// ListAllKeys 返回全部附件索引对应的对象键，供后台对账比对 attachments/
	// 下的对象：库里查不到的键是遗留字节，见 ADR-0037。
	ListAllKeys(ctx context.Context) ([]string, error)
	// DeleteUser 删除账号名下的全部附件与索引。
	DeleteUser(ctx context.Context, userID string) error
}

// ObjectStore 是生产实现：附件键放在共享的对象存储里，配额索引留在进程内存。
//
// 索引只在内存里的代价是重启之后配额从 0 重新算起；PostgreSQL 装配下改用
// pg.Store 的 attachment 表，索引与账号一起持久化。
type ObjectStore struct {
	objects objectstore.Store

	// mu 保护 index。键是账号，值是 sha256 到字节数；只记配额需要的索引，
	// 字节本身在 objects 里。
	mu    sync.Mutex
	index map[string]map[string]int64
}

// NewStore 用给定的对象存储实现附件存储。
func NewStore(objects objectstore.Store) *ObjectStore {
	return &ObjectStore{objects: objects, index: map[string]map[string]int64{}}
}

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

// Reserve 在锁内完成“查重、求和、写入”，同一账号的两次预留因此排队；limit
// 小于等于 0 表示不设上限（只有测试与本地联调会这样配）。
func (o *ObjectStore) Reserve(_ context.Context, userID, sha string, size, limit int64) (int64, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	files := o.index[userID]
	if _, ok := files[sha]; ok {
		return sumSizes(files), nil
	}
	used := sumSizes(files)
	if limit > 0 && used+size > limit {
		return used, &StorageFullError{Used: used, Limit: limit}
	}
	if files == nil {
		files = map[string]int64{}
		o.index[userID] = files
	}
	files[sha] = size
	return used + size, nil
}

// Release 先看字节是否还在：还在说明这次保存失败的是本次写入，同一内容的并发
// 上传可能已经成功并把索引建好，删掉索引会让配额少算；只有字节确实不存在时才
// 撤销索引。
func (o *ObjectStore) Release(ctx context.Context, userID, sha string, _ int64) error {
	if _, err := o.objects.Stat(ctx, objectstore.AttachmentKey(userID, sha)); err == nil {
		return nil
	} else if !errors.Is(err, objectstore.ErrNotFound) {
		return err
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if files := o.index[userID]; files != nil {
		delete(files, sha)
		if len(files) == 0 {
			delete(o.index, userID)
		}
	}
	return nil
}

func (o *ObjectStore) Used(_ context.Context, userID string) (int64, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return sumSizes(o.index[userID]), nil
}

// ListAllKeys 按内存索引拼出对象键；重建进程之后索引为空，这与内存对象存储
// 一起丢失字节的语义一致（进程内实现只用于开发与测试）。
func (o *ObjectStore) ListAllKeys(_ context.Context) ([]string, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	var out []string
	for userID, files := range o.index {
		for sha := range files {
			out = append(out, objectstore.AttachmentKey(userID, sha))
		}
	}
	return out, nil
}

func (o *ObjectStore) DeleteUser(ctx context.Context, userID string) error {
	o.mu.Lock()
	delete(o.index, userID)
	o.mu.Unlock()
	return o.objects.RemovePrefix(ctx, objectstore.AttachmentPrefix(userID))
}

func sumSizes(files map[string]int64) int64 {
	var total int64
	for _, size := range files {
		total += size
	}
	return total
}

func mapErr(err error) error {
	if errors.Is(err, objectstore.ErrNotFound) {
		return ErrNotFound
	}
	return err
}
