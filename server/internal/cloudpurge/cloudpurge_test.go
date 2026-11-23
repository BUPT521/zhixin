package cloudpurge

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// fakeBackups、fakeSync、fakeBlobs 记录调用次数，并可按顺序注入失败，用来
// 覆盖编排顺序与失败之后各步的行为。
type fakeBackups struct {
	calls int
	errs  []error
}

func (f *fakeBackups) DeleteAll(context.Context, string) error {
	f.calls++
	return popErr(&f.errs)
}

type fakeSync struct {
	calls int
	errs  []error
}

func (f *fakeSync) Reset(context.Context, string) error {
	f.calls++
	return popErr(&f.errs)
}

type fakeBlobs struct {
	calls int
	errs  []error
}

func (f *fakeBlobs) DeleteUser(context.Context, string) error {
	f.calls++
	return popErr(&f.errs)
}

// fakeEmbeddings 是嵌入向量缓存的清空步骤。缓存是派生数据，仍然要和其余几类
// 数据一起清，清除顺序与失败之后的行为都要覆盖。实现里的 PurgeUser 在同一把
// 账号锁中加代次并删行，编排只关心它被调用一次、失败时原样返回错误。
type fakeEmbeddings struct {
	calls int
	errs  []error
}

func (f *fakeEmbeddings) PurgeUser(context.Context, string) error {
	f.calls++
	return popErr(&f.errs)
}

func popErr(errs *[]error) error {
	if len(*errs) == 0 {
		return nil
	}
	err := (*errs)[0]
	*errs = (*errs)[1:]
	return err
}

// seedAccountObjects 在备份与附件两个前缀下各写一个对象。
func seedAccountObjects(t *testing.T, objects objectstore.Store, userID, sha string) {
	t.Helper()
	ctx := context.Background()
	for _, key := range []string{
		objectstore.BackupKey(userID, "b1"),
		objectstore.AttachmentKey(userID, sha),
	} {
		body := []byte("bytes")
		if err := objects.Put(ctx, key, bytes.NewReader(body), objectstore.Info{Size: int64(len(body))}); err != nil {
			t.Fatalf("seed %s: %v", key, err)
		}
	}
}

func shaFor(letter string) string { return string(bytes.Repeat([]byte(letter), 64)) }

// TestPurgeClearsEverythingAndLeftoverObjects 守住一次成功清除做了哪些事：
// 四类数据各清一次，两个账号前缀下的遗留对象都清掉，别的账号不受影响；清除
// 可重复调用，所以空账号再清一次也成功（审查 9.3 的 V10：中途失败由用户重试）。
func TestPurgeClearsEverythingAndLeftoverObjects(t *testing.T) {
	ctx := context.Background()
	objects := objectstore.NewMemory()
	seedAccountObjects(t, objects, "u1", shaFor("a"))
	seedAccountObjects(t, objects, "u2", shaFor("b"))
	backups := &fakeBackups{}
	syncLog := &fakeSync{}
	blobs := &fakeBlobs{}
	embeddings := &fakeEmbeddings{}
	svc := New(backups, syncLog, blobs, embeddings, objects)

	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("purge: %v", err)
	}
	if backups.calls != 1 || syncLog.calls != 1 || blobs.calls != 1 || embeddings.calls != 1 {
		t.Fatalf("calls: backups %d, sync %d, blobs %d, embeddings %d",
			backups.calls, syncLog.calls, blobs.calls, embeddings.calls)
	}
	for _, key := range []string{
		objectstore.BackupKey("u1", "b1"),
		objectstore.AttachmentKey("u1", shaFor("a")),
	} {
		if _, err := objects.Stat(ctx, key); !errors.Is(err, objectstore.ErrNotFound) {
			t.Fatalf("leftover object %s: %v", key, err)
		}
	}
	for _, key := range []string{
		objectstore.BackupKey("u2", "b1"),
		objectstore.AttachmentKey("u2", shaFor("b")),
	} {
		if _, err := objects.Stat(ctx, key); err != nil {
			t.Fatalf("another account's object %s was removed: %v", key, err)
		}
	}

	// 各步幂等：同一个账号马上可以再清一次。
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("second purge: %v", err)
	}
	if backups.calls != 2 || embeddings.calls != 2 {
		t.Fatalf("second purge calls: backups %d, embeddings %d", backups.calls, embeddings.calls)
	}
}

// TestPurgeStopsAtFirstFailure 守住失败之后的行为：出错的步骤之后不再执行，错误
// 原样返回；用户重试时从头执行各步并成功（审查 9.3 的 V10）。
func TestPurgeStopsAtFirstFailure(t *testing.T) {
	ctx := context.Background()
	boom := errors.New("备份存储不可用")
	backups := &fakeBackups{errs: []error{boom}}
	syncLog := &fakeSync{}
	blobs := &fakeBlobs{}
	embeddings := &fakeEmbeddings{}
	svc := New(backups, syncLog, blobs, embeddings, objectstore.NewMemory())

	if err := svc.Purge(ctx, "u1"); !errors.Is(err, boom) {
		t.Fatalf("purge failure: want %v, got %v", boom, err)
	}
	if syncLog.calls != 0 || blobs.calls != 0 || embeddings.calls != 0 {
		t.Fatalf("steps after the failure must not run: sync %d, blobs %d, embeddings %d",
			syncLog.calls, blobs.calls, embeddings.calls)
	}

	// 重试从头执行各步并成功。
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if backups.calls != 2 || syncLog.calls != 1 || blobs.calls != 1 || embeddings.calls != 1 {
		t.Fatalf("retry calls: backups %d, sync %d, blobs %d, embeddings %d",
			backups.calls, syncLog.calls, blobs.calls, embeddings.calls)
	}
}

// TestPurgeEmbeddingFailureIsReturned 守住嵌入缓存这一步失败时的行为：错误原样
// 返回，前缀清理不再执行；重试时各步从头再走一遍。代次加一与删行在实现里是同
// 一个事务，失败就没有清掉任何缓存行（ADR-0037）。
func TestPurgeEmbeddingFailureIsReturned(t *testing.T) {
	ctx := context.Background()
	boom := errors.New("嵌入缓存清理不可用")
	embeddings := &fakeEmbeddings{errs: []error{boom}}
	svc := New(&fakeBackups{}, &fakeSync{}, &fakeBlobs{}, embeddings, objectstore.NewMemory())

	if err := svc.Purge(ctx, "u1"); !errors.Is(err, boom) {
		t.Fatalf("purge failure: want %v, got %v", boom, err)
	}
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if embeddings.calls != 2 {
		t.Fatalf("embeddings calls = %d, want 2", embeddings.calls)
	}
}
