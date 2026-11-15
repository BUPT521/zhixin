package blobs

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

const shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func TestStoreRoundTrip(t *testing.T) {
	ctx := context.Background()
	s := NewStore(objectstore.NewMemory())
	body := []byte("attachment")

	if err := s.Save(ctx, "u1", shaA, int64(len(body)), bytes.NewReader(body)); err != nil {
		t.Fatalf("Save: %v", err)
	}
	size, err := s.Stat(ctx, "u1", shaA)
	if err != nil || size != int64(len(body)) {
		t.Fatalf("Stat: %d %v", size, err)
	}
	rc, size, err := s.Open(ctx, "u1", shaA)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	got, _ := io.ReadAll(rc)
	_ = rc.Close()
	if !bytes.Equal(got, body) || size != int64(len(body)) {
		t.Fatalf("content %q size %d", got, size)
	}

	// 附件按账号隔离：同一个哈希在另一个账号名下不存在。
	if _, err := s.Stat(ctx, "u2", shaA); !errors.Is(err, ErrNotFound) {
		t.Fatalf("other account must not see the attachment, got %v", err)
	}
	if _, _, err := s.Open(ctx, "u2", shaA); !errors.Is(err, ErrNotFound) {
		t.Fatalf("other account Open: %v", err)
	}
}

func TestStoreSaveChecksSize(t *testing.T) {
	s := NewStore(objectstore.NewMemory())
	if err := s.Save(context.Background(), "u1", shaA, 1, bytes.NewReader([]byte("too long"))); err == nil {
		t.Fatal("保存长度与声明不符时应当失败")
	}
}

func TestStoreDeleteUser(t *testing.T) {
	ctx := context.Background()
	s := NewStore(objectstore.NewMemory())
	for _, u := range []string{"u1", "u2"} {
		if err := s.Save(ctx, u, shaA, 1, bytes.NewReader([]byte("x"))); err != nil {
			t.Fatalf("Save %s: %v", u, err)
		}
	}
	if err := s.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}
	if _, err := s.Stat(ctx, "u1", shaA); !errors.Is(err, ErrNotFound) {
		t.Fatalf("u1 attachment should be gone, got %v", err)
	}
	if _, err := s.Stat(ctx, "u2", shaA); err != nil {
		t.Fatalf("u2 attachment should stay: %v", err)
	}
}
