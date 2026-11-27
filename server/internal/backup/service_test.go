package backup

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// TestServiceUploadStoresMetadata 守住服务层只做自己那一段：schema 与大小已由
// 处理器在 HTTP 入口核对，这里原样写进元数据，设备名清洗后落库。
func TestServiceUploadStoresMetadata(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 8, 2, 27)

	meta, err := svc.Upload(ctx, "u1", "sha", 27, "  phone  ", 4, strings.NewReader("zip1"))
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	if meta.DeviceName != "phone" || meta.Size != 4 || meta.SchemaVersion != 27 {
		t.Fatalf("meta = %+v", meta)
	}
	list, err := svc.List(ctx, "u1")
	if err != nil || len(list) != 1 || list[0].ID != meta.ID {
		t.Fatalf("list = %+v, %v", list, err)
	}
}

func TestServiceKeepsNewestSnapshots(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 8, 2, 27)
	for _, body := range []string{"a", "b", "c"} {
		if _, err := svc.Upload(ctx, "u1", "sha-"+body, 27, "", 1, strings.NewReader(body)); err != nil {
			t.Fatalf("upload %s: %v", body, err)
		}
	}
	list, err := svc.List(ctx, "u1")
	if err != nil || len(list) != 2 {
		t.Fatalf("list = %+v, %v", list, err)
	}
	if list[0].SHA256 != "sha-c" || list[1].SHA256 != "sha-b" {
		t.Fatalf("list order = %+v", list)
	}
}

// TestServiceDeleteScopesToAccountAndRejectsBadIDs 守住删除的归属与 id 形状：
// 别的账号的 id 删不掉，形状不合法的 id 一律按“没有这份备份”处理，自己的备份
// 正常删除，重复删除停在 ErrNotFound。
func TestServiceDeleteScopesToAccountAndRejectsBadIDs(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 64, 2, 27)

	mine, err := svc.Upload(ctx, "u1", "sha-1", 27, "", 1, strings.NewReader("a"))
	if err != nil {
		t.Fatalf("upload u1: %v", err)
	}
	other, err := svc.Upload(ctx, "u2", "sha-2", 27, "", 1, strings.NewReader("b"))
	if err != nil {
		t.Fatalf("upload u2: %v", err)
	}

	// 拿另一个账号的 id 删：数据库层按 (user_id, id) 查不到行，两边都还在。
	if err := svc.Delete(ctx, "u1", other.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleting another account's backup: want ErrNotFound, got %v", err)
	}
	if list, err := svc.List(ctx, "u2"); err != nil || len(list) != 1 {
		t.Fatalf("other account backup disappeared: %+v, %v", list, err)
	}
	if _, rc, err := svc.Open(ctx, "u2", other.ID); err != nil {
		t.Fatalf("other account backup unreadable: %v", err)
	} else {
		_ = rc.Close()
	}

	// 非法 id 不产生删除，也不返回 500：契约里这个路径只有 404。
	for _, id := range []string{
		"", "abc", strings.Repeat("A", 32), strings.Repeat("g", 32),
		mine.ID + "0", "../u2/" + other.ID,
	} {
		if err := svc.Delete(ctx, "u1", id); !errors.Is(err, ErrNotFound) {
			t.Errorf("Delete(%q): want ErrNotFound, got %v", id, err)
		}
		if _, rc, err := svc.Open(ctx, "u1", id); !errors.Is(err, ErrNotFound) {
			if rc != nil {
				_ = rc.Close()
			}
			t.Errorf("Open(%q): want ErrNotFound, got %v", id, err)
		}
	}
	if list, err := svc.List(ctx, "u1"); err != nil || len(list) != 1 || list[0].ID != mine.ID {
		t.Fatalf("invalid ids changed the account's backups: %+v, %v", list, err)
	}

	// 自己的 id 正常删除；删过之后再删一次按不存在处理。
	if err := svc.Delete(ctx, "u1", mine.ID); err != nil {
		t.Fatalf("delete own backup: %v", err)
	}
	if err := svc.Delete(ctx, "u1", mine.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: want ErrNotFound, got %v", err)
	}
}

// TestServiceDeleteAllClearsOnlyThatAccount 守住清空的范围：只删指定账号的备份，
// 元数据与字节一起消失；另一个账号的备份仍可列出与打开；空账号再清一次不算错误。
func TestServiceDeleteAllClearsOnlyThatAccount(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 8, 2, 27)

	gone, err := svc.Upload(ctx, "u1", "sha-1", 27, "", 1, strings.NewReader("a"))
	if err != nil {
		t.Fatalf("upload u1: %v", err)
	}
	kept, err := svc.Upload(ctx, "u2", "sha-2", 27, "", 1, strings.NewReader("b"))
	if err != nil {
		t.Fatalf("upload u2: %v", err)
	}

	if err := svc.DeleteAll(ctx, "u1"); err != nil {
		t.Fatalf("delete all: %v", err)
	}
	if list, err := svc.List(ctx, "u1"); err != nil || len(list) != 0 {
		t.Fatalf("list after clear = %+v, %v", list, err)
	}
	if _, _, err := svc.Open(ctx, "u1", gone.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("bytes after clear: want ErrNotFound, got %v", err)
	}
	list, err := svc.List(ctx, "u2")
	if err != nil || len(list) != 1 || list[0].ID != kept.ID {
		t.Fatalf("other account list = %+v, %v", list, err)
	}
	_, rc, err := svc.Open(ctx, "u2", kept.ID)
	if err != nil {
		t.Fatalf("other account open: %v", err)
	}
	_ = rc.Close()

	// 已经空的账号再清一次也成功，客户端重试无需先列表判断。
	if err := svc.DeleteAll(ctx, "u1"); err != nil {
		t.Fatalf("second clear: %v", err)
	}
}

// TestMemoryStoreRejectsInvalidKeep 守住保留份数的存储边界：keep 小于 1 时两种
// 实现都返回 ErrKeep 并保持原数据，不把 0 解释成清空、负数解释成不裁剪。
func TestMemoryStoreRejectsInvalidKeep(t *testing.T) {
	ctx := context.Background()
	store := NewMemoryStore()
	meta := Meta{ID: newID(), CreatedAt: time.Now().UTC()}
	if err := store.Put(ctx, "u1", meta, strings.NewReader("x"), 0); !errors.Is(err, ErrKeep) {
		t.Fatalf("keep=0: want ErrKeep, got %v", err)
	}
	if items, err := store.List(ctx, "u1"); err != nil || len(items) != 0 {
		t.Fatalf("被拒绝的写入不应留下数据: %+v %v", items, err)
	}
}
