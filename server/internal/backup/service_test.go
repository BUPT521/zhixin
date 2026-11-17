package backup

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestServiceUploadValidatesSchemaAndSize(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 8, 2, 27)

	if _, err := svc.Upload(ctx, "u1", "sha", 25, "", 1, strings.NewReader("x")); !errors.Is(err, ErrSchemaVersion) {
		t.Fatalf("other schema: want ErrSchemaVersion, got %v", err)
	}
	if _, err := svc.Upload(ctx, "u1", "sha", 27, "", 9, strings.NewReader("x")); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize: want ErrTooLarge, got %v", err)
	}

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
