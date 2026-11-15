package objectstore

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"
)

// 三种实现共用一组行为断言：写入后能取回、大小声明不符时拒绝、删除后不存在、
// 按前缀清理只删自己账号的对象。
func testStore(t *testing.T, newStore func(t *testing.T) Store) {
	t.Helper()
	ctx := context.Background()
	s := newStore(t)

	body := []byte("backup-bytes")
	if err := s.Put(ctx, "backups/u1/b1.zip", bytes.NewReader(body), Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	info, err := s.Stat(ctx, "backups/u1/b1.zip")
	if err != nil || info.Size != int64(len(body)) {
		t.Fatalf("Stat: %+v %v", info, err)
	}
	rc, info, err := s.Open(ctx, "backups/u1/b1.zip")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	got, _ := io.ReadAll(rc)
	_ = rc.Close()
	if !bytes.Equal(got, body) || info.Size != int64(len(body)) {
		t.Fatalf("Open body %q size %d", got, info.Size)
	}

	if err := s.Put(ctx, "backups/u1/b2.zip", bytes.NewReader(body), Info{Size: 1}); err == nil {
		t.Fatal("Put with a wrong size must fail")
	}
	if _, err := s.Stat(ctx, "backups/u1/b2.zip"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("partial object must not be visible, got %v", err)
	}

	if err := s.Put(ctx, "attachments/u1/aa", bytes.NewReader(body), Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("Put attachment: %v", err)
	}
	if err := s.Put(ctx, "attachments/u2/bb", bytes.NewReader(body), Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("Put other attachment: %v", err)
	}
	if err := s.RemovePrefix(ctx, "attachments/u1/"); err != nil {
		t.Fatalf("RemovePrefix: %v", err)
	}
	if _, err := s.Stat(ctx, "attachments/u1/aa"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("u1 attachment should be gone, got %v", err)
	}
	if _, err := s.Stat(ctx, "attachments/u2/bb"); err != nil {
		t.Fatalf("u2 attachment should stay: %v", err)
	}

	if err := s.Remove(ctx, "attachments/u2/bb"); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if err := s.Remove(ctx, "attachments/u2/bb"); err != nil {
		t.Fatalf("Remove of a missing object must be a no-op: %v", err)
	}
	if err := s.Ping(ctx); err != nil {
		t.Fatalf("Ping: %v", err)
	}
}

func TestMemory(t *testing.T) {
	testStore(t, func(*testing.T) Store { return NewMemory() })
}

func TestDir(t *testing.T) {
	testStore(t, func(t *testing.T) Store {
		d, err := NewDir(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		return d
	})
}

func TestDirRejectsTraversal(t *testing.T) {
	d, err := NewDir(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Stat(context.Background(), "../escape"); err == nil {
		t.Fatal("a key outside the root must be rejected")
	}
	if _, err := d.Stat(context.Background(), ""); err == nil {
		t.Fatal("an empty key must be rejected")
	}
}

func TestNewDirRequiresRoot(t *testing.T) {
	if _, err := NewDir("  "); err == nil {
		t.Fatal("an empty root must be rejected")
	}
}

func TestS3RejectsIncompleteOptions(t *testing.T) {
	if _, err := NewS3(S3Config{Endpoint: "minio:9000", Bucket: "zhixin"}); err == nil {
		t.Fatal("missing credentials must be rejected")
	}
}
