package blobs

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
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

// TestStoreListAllKeys 核对索引里的每一行都按对象键规则列出，供备份对账求差集：
// 两个账号的两份内容都在，没有索引的遗留字节不会从索引凭空出现。
func TestStoreListAllKeys(t *testing.T) {
	ctx := context.Background()
	s := NewStore(objectstore.NewMemory())
	shaB := strings.Repeat("b", 64)
	if _, err := s.Reserve(ctx, "u1", shaA, 1, 0); err != nil {
		t.Fatalf("reserve u1: %v", err)
	}
	if _, err := s.Reserve(ctx, "u2", shaB, 2, 0); err != nil {
		t.Fatalf("reserve u2: %v", err)
	}

	keys, err := s.ListAllKeys(ctx)
	if err != nil {
		t.Fatalf("list all keys: %v", err)
	}
	got := make(map[string]bool, len(keys))
	for _, key := range keys {
		got[key] = true
	}
	for _, want := range []string{
		objectstore.AttachmentKey("u1", shaA),
		objectstore.AttachmentKey("u2", shaB),
	} {
		if !got[want] {
			t.Fatalf("ListAllKeys 缺少 %q，得到 %v", want, keys)
		}
	}
	if len(keys) != 2 {
		t.Fatalf("ListAllKeys 应返回 2 个键，得到 %v", keys)
	}
}

// TestStoreQuotaReserveRelease 守住预留的语义：重复 sha 不重复计数、超限时带
// 已用量与上限且不改状态、保存失败回滚、字节已存在时不撤销索引、删账号清空。
func TestStoreQuotaReserveRelease(t *testing.T) {
	ctx := context.Background()
	s := NewStore(objectstore.NewMemory())
	shaB := strings.Repeat("b", 64)

	// 同一 sha 重复预留只算一次。
	if used, err := s.Reserve(ctx, "u1", shaA, 4, 10); err != nil || used != 4 {
		t.Fatalf("first reserve: used %d, err %v", used, err)
	}
	if used, err := s.Reserve(ctx, "u1", shaA, 4, 10); err != nil || used != 4 {
		t.Fatalf("duplicate reserve: used %d, err %v", used, err)
	}

	// 超限返回带已用量与上限的错误，状态不变。
	used, err := s.Reserve(ctx, "u1", shaB, 7, 10)
	var full *StorageFullError
	if !errors.Is(err, ErrStorageFull) || !errors.As(err, &full) {
		t.Fatalf("over limit: want StorageFullError, got %v", err)
	}
	if used != 4 || full.Used != 4 || full.Limit != 10 {
		t.Fatalf("over limit numbers: used %d, full %+v", used, full)
	}

	// 字节没写成功时撤销预留，已用量回到 0。
	if err := s.Release(ctx, "u1", shaA, 4); err != nil {
		t.Fatalf("release: %v", err)
	}
	if used, _ = s.Used(ctx, "u1"); used != 0 {
		t.Fatalf("used after release = %d", used)
	}

	// 字节已经在存储里时不删索引：同一内容的并发上传可能已经写成功。
	body := []byte("attachment")
	size := int64(len(body))
	if used, err := s.Reserve(ctx, "u1", shaB, size, 10); err != nil || used != size {
		t.Fatalf("reserve after release: used %d, err %v", used, err)
	}
	if err := s.Save(ctx, "u1", shaB, size, bytes.NewReader(body)); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if err := s.Release(ctx, "u1", shaB, size); err != nil {
		t.Fatalf("release with bytes: %v", err)
	}
	if used, _ = s.Used(ctx, "u1"); used != size {
		t.Fatalf("release must keep the index while bytes exist, used = %d", used)
	}

	// 账号之间互不影响。
	if used, _ = s.Used(ctx, "u2"); used != 0 {
		t.Fatalf("another account was charged: %d", used)
	}

	// 删账号清字节与索引。
	if err := s.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}
	if used, _ = s.Used(ctx, "u1"); used != 0 {
		t.Fatalf("used after DeleteUser = %d", used)
	}
	if _, err := s.Stat(ctx, "u1", shaB); !errors.Is(err, ErrNotFound) {
		t.Fatalf("bytes after DeleteUser: %v", err)
	}
}
