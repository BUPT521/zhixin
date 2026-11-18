package cloudpurge

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// fakeBackups、fakeSync、fakeBlobs 记录调用次数，并可按顺序注入失败，用来
// 覆盖编排顺序与失败保留标记的行为。
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
// 三类数据各清一次，两个账号前缀下的遗留对象都清掉，别的账号不受影响，标记
// 在结束时删除（所以空账号再清一次也成功）。
func TestPurgeClearsEverythingAndLeftoverObjects(t *testing.T) {
	ctx := context.Background()
	objects := objectstore.NewMemory()
	seedAccountObjects(t, objects, "u1", shaFor("a"))
	seedAccountObjects(t, objects, "u2", shaFor("b"))
	backups := &fakeBackups{}
	syncLog := &fakeSync{}
	blobs := &fakeBlobs{}
	svc := New(NewMemoryStore(), backups, syncLog, blobs, objects)

	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("purge: %v", err)
	}
	if backups.calls != 1 || syncLog.calls != 1 || blobs.calls != 1 {
		t.Fatalf("calls: backups %d, sync %d, blobs %d", backups.calls, syncLog.calls, blobs.calls)
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

	// 标记已删：同一个账号马上可以再清一次。
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("second purge: %v", err)
	}
}

// TestPurgeRejectsConcurrentRequestAndGatesWrites 守住标记的两个作用：新标记
// 期间第二次清除返回 ErrInProgress（409），写处理器拿到 ErrPurging；标记超过
// 10 分钟视为上次中断，写放行、新的清除接管并把标记删掉。
func TestPurgeRejectsConcurrentRequestAndGatesWrites(t *testing.T) {
	ctx := context.Background()
	marker := NewMemoryStore()
	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	svc := New(marker, &fakeBackups{}, &fakeSync{}, &fakeBlobs{}, objectstore.NewMemory())
	svc.now = func() time.Time { return now }

	if err := svc.Gate(ctx, "u1"); err != nil {
		t.Fatalf("gate without a purge: %v", err)
	}
	// 模拟一次已经开始、还没结束的清除。
	claimed, err := marker.ClaimPurge(ctx, "u1", now, now.Add(-StaleAfter))
	if err != nil || !claimed {
		t.Fatalf("seed marker: claimed %v, err %v", claimed, err)
	}
	if err := svc.Purge(ctx, "u1"); !errors.Is(err, ErrInProgress) {
		t.Fatalf("concurrent purge: want ErrInProgress, got %v", err)
	}
	if err := svc.Gate(ctx, "u1"); !errors.Is(err, ErrPurging) {
		t.Fatalf("gate during purge: want ErrPurging, got %v", err)
	}

	// 超过有效期：上一次视为中断，写入放行，新的清除接管并完成。
	now = now.Add(StaleAfter + time.Minute)
	if err := svc.Gate(ctx, "u1"); err != nil {
		t.Fatalf("gate after stale marker: %v", err)
	}
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("takeover purge: %v", err)
	}
	if _, ok, err := marker.PurgeStartedAt(ctx, "u1"); err != nil || ok {
		t.Fatalf("marker should be removed, ok=%v err=%v", ok, err)
	}
}

// TestPurgeFailureKeepsMarkerAndRetryCompletes 守住失败后的行为：出错的步骤
// 之后不再执行，标记保留，立即重试回 409；过了有效期之后重试从头执行各步并
// 成功，标记删除。
func TestPurgeFailureKeepsMarkerAndRetryCompletes(t *testing.T) {
	ctx := context.Background()
	marker := NewMemoryStore()
	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	boom := errors.New("备份存储不可用")
	backups := &fakeBackups{errs: []error{boom}}
	syncLog := &fakeSync{}
	blobs := &fakeBlobs{}
	svc := New(marker, backups, syncLog, blobs, objectstore.NewMemory())
	svc.now = func() time.Time { return now }

	if err := svc.Purge(ctx, "u1"); !errors.Is(err, boom) {
		t.Fatalf("purge failure: want %v, got %v", boom, err)
	}
	if syncLog.calls != 0 || blobs.calls != 0 {
		t.Fatalf("steps after the failure must not run: sync %d, blobs %d", syncLog.calls, blobs.calls)
	}
	if _, ok, err := marker.PurgeStartedAt(ctx, "u1"); err != nil || !ok {
		t.Fatalf("marker must survive a failure, ok=%v err=%v", ok, err)
	}
	if err := svc.Purge(ctx, "u1"); !errors.Is(err, ErrInProgress) {
		t.Fatalf("immediate retry: want ErrInProgress, got %v", err)
	}

	// 过了有效期，重试从头执行并成功。
	now = now.Add(StaleAfter + time.Minute)
	if err := svc.Purge(ctx, "u1"); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if backups.calls != 2 || syncLog.calls != 1 || blobs.calls != 1 {
		t.Fatalf("retry calls: backups %d, sync %d, blobs %d", backups.calls, syncLog.calls, blobs.calls)
	}
	if _, ok, _ := marker.PurgeStartedAt(ctx, "u1"); ok {
		t.Fatal("marker should be removed after a successful retry")
	}
}
