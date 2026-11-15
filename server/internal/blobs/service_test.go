package blobs

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

func TestServicePutRespectsLimit(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewStore(objectstore.NewMemory()), 4)

	if err := svc.Put(ctx, "u1", "sha", 5, bytes.NewReader([]byte("12345"))); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize: want ErrTooLarge, got %v", err)
	}
	if err := svc.Put(ctx, "u1", "sha", 4, bytes.NewReader([]byte("1234"))); err != nil {
		t.Fatalf("put: %v", err)
	}
	size, err := svc.Stat(ctx, "u1", "sha")
	if err != nil || size != 4 {
		t.Fatalf("stat = %d, %v", size, err)
	}
	rc, size, err := svc.Open(ctx, "u1", "sha")
	if err != nil || size != 4 {
		t.Fatalf("open = %d, %v", size, err)
	}
	defer rc.Close()
	got, _ := io.ReadAll(rc)
	if string(got) != "1234" {
		t.Fatalf("bytes = %q", got)
	}
	if _, err := svc.Stat(ctx, "other", "sha"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("other account: want ErrNotFound, got %v", err)
	}
}
