package backup

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// TestReconcileRemovesOnlyStaleOrphans 核对对账的三条边界：元数据在、对象也在
// 时不删；对象没有元数据且超过宽限期时删掉；对象没有元数据但刚写入时保留，
// 避免删掉一次正在进行中的上传。
func TestReconcileRemovesOnlyStaleOrphans(t *testing.T) {
	ctx := context.Background()
	objects := objectstore.NewMemory()
	store := NewMemoryStore()
	svc := NewService(store, 1<<20, 2, 27)
	svc.SetObjects(objects)
	fixed := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)
	svc.now = func() time.Time { return fixed }

	// 元数据在、对象也在：上传之后把同一份字节放进对象存储，对账不能动它。
	meta, err := svc.Upload(ctx, "u1", "sha-live", 27, "", 4, strings.NewReader("zip1"))
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	liveKey := objectstore.BackupKey("u1", meta.ID)
	if err := objects.Put(ctx, liveKey, strings.NewReader("zip1"), objectstore.Info{Size: 4}); err != nil {
		t.Fatalf("put live object: %v", err)
	}

	// 对象在、元数据没有且够旧：删除。
	staleKey := objectstore.BackupKey("u2", strings.Repeat("a", 32))
	if err := objects.PutAt(ctx, staleKey, strings.NewReader("old"),
		objectstore.Info{Size: 3}, fixed.Add(-2*ReconcileGrace)); err != nil {
		t.Fatalf("put stale object: %v", err)
	}

	// 对象在、元数据没有但刚写入：保留。
	freshKey := objectstore.BackupKey("u3", strings.Repeat("b", 32))
	if err := objects.PutAt(ctx, freshKey, strings.NewReader("new"),
		objectstore.Info{Size: 3}, fixed.Add(-time.Minute)); err != nil {
		t.Fatalf("put fresh object: %v", err)
	}

	removed, err := svc.Reconcile(ctx)
	if err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	if removed != 1 {
		t.Fatalf("只应删掉一个遗留对象，删了 %d 个", removed)
	}
	if _, err := objects.Stat(ctx, staleKey); !errors.Is(err, objectstore.ErrNotFound) {
		t.Fatalf("超过宽限期的遗留对象应被删除，得到 %v", err)
	}
	if _, err := objects.Stat(ctx, liveKey); err != nil {
		t.Fatalf("有元数据的对象不能删: %v", err)
	}
	if _, err := objects.Stat(ctx, freshKey); err != nil {
		t.Fatalf("宽限期内的对象不能删: %v", err)
	}
	// 对账只动对象存储，元数据原样保留。
	if list, err := svc.List(ctx, "u1"); err != nil || len(list) != 1 || list[0].ID != meta.ID {
		t.Fatalf("元数据不应变化: %+v, %v", list, err)
	}
}

// TestReconcileKeepsAttachments 核对对账的范围：只列 backups/ 前缀，attachments/
// 下的对象即使没有元数据也不会被删，那部分由附件自己的前缀清理负责。
func TestReconcileKeepsAttachments(t *testing.T) {
	ctx := context.Background()
	objects := objectstore.NewMemory()
	svc := NewService(NewMemoryStore(), 1<<20, 2, 27)
	svc.SetObjects(objects)
	fixed := time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC)
	svc.now = func() time.Time { return fixed }

	attachmentKey := objectstore.AttachmentKey("u1", strings.Repeat("c", 64))
	if err := objects.PutAt(ctx, attachmentKey, strings.NewReader("att"),
		objectstore.Info{Size: 3}, fixed.Add(-2*ReconcileGrace)); err != nil {
		t.Fatalf("put attachment: %v", err)
	}

	removed, err := svc.Reconcile(ctx)
	if err != nil || removed != 0 {
		t.Fatalf("对账应只处理备份对象: removed=%d err=%v", removed, err)
	}
	if _, err := objects.Stat(ctx, attachmentKey); err != nil {
		t.Fatalf("附件对象不能删: %v", err)
	}
}

// TestMemoryStoreListAllKeys 核对内存实现把每条元数据都拼成与对象存储一致的键，
// 对账拿它求差集。
func TestMemoryStoreListAllKeys(t *testing.T) {
	ctx := context.Background()
	store := NewMemoryStore()
	for _, item := range []struct{ userID, id string }{{"u1", "b1"}, {"u2", "b2"}} {
		meta := Meta{ID: item.id, CreatedAt: time.Now().UTC()}
		if err := store.Put(ctx, item.userID, meta, bytes.NewReader([]byte("zip")), 2); err != nil {
			t.Fatalf("put %s/%s: %v", item.userID, item.id, err)
		}
	}

	keys, err := store.ListAllKeys(ctx)
	if err != nil {
		t.Fatalf("list all keys: %v", err)
	}
	got := make(map[string]bool, len(keys))
	for _, key := range keys {
		got[key] = true
	}
	for _, want := range []string{objectstore.BackupKey("u1", "b1"), objectstore.BackupKey("u2", "b2")} {
		if !got[want] {
			t.Fatalf("ListAllKeys 缺少 %q，得到 %v", want, keys)
		}
	}
	if len(keys) != 2 {
		t.Fatalf("ListAllKeys 应返回 2 个键，得到 %v", keys)
	}
}
