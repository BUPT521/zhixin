package backup

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestServiceUploadValidatesSchemaAndSize(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 8, 2, 26)

	if _, err := svc.Upload(ctx, "u1", "sha", 25, "", 1, strings.NewReader("x")); !errors.Is(err, ErrSchemaVersion) {
		t.Fatalf("other schema: want ErrSchemaVersion, got %v", err)
	}
	if _, err := svc.Upload(ctx, "u1", "sha", 26, "", 9, strings.NewReader("x")); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize: want ErrTooLarge, got %v", err)
	}

	meta, err := svc.Upload(ctx, "u1", "sha", 26, "  phone  ", 4, strings.NewReader("zip1"))
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	if meta.DeviceName != "phone" || meta.Size != 4 || meta.SchemaVersion != 26 {
		t.Fatalf("meta = %+v", meta)
	}
	list, err := svc.List(ctx, "u1")
	if err != nil || len(list) != 1 || list[0].ID != meta.ID {
		t.Fatalf("list = %+v, %v", list, err)
	}
}

func TestServiceKeepsNewestSnapshots(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 8, 2, 26)
	for _, body := range []string{"a", "b", "c"} {
		if _, err := svc.Upload(ctx, "u1", "sha-"+body, 26, "", 1, strings.NewReader(body)); err != nil {
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
