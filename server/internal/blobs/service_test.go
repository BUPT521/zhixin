package blobs

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// TestServicePutStoresBytes 守住服务层的写入与读取：大小已由处理器在 HTTP
// 入口核对，这里只预留配额、写字节并读回。
func TestServicePutStoresBytes(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewStore(objectstore.NewMemory()), 4).SetAccountBytes(1024)

	if err := svc.Put(ctx, "u1", "sha", 4, bytes.NewReader([]byte("1234"))); err != nil {
		t.Fatalf("put: %v", err)
	}
	size, err := svc.store.Stat(ctx, "u1", "sha")
	if err != nil || size != 4 {
		t.Fatalf("stat = %d, %v", size, err)
	}
	rc, size, err := svc.store.Open(ctx, "u1", "sha")
	if err != nil || size != 4 {
		t.Fatalf("open = %d, %v", size, err)
	}
	defer rc.Close()
	got, _ := io.ReadAll(rc)
	if string(got) != "1234" {
		t.Fatalf("bytes = %q", got)
	}
	if _, err := svc.store.Stat(ctx, "other", "sha"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("other account: want ErrNotFound, got %v", err)
	}
}

// TestServicePutQuotaIsAtomic 守住并发上传的配额：两个各占 6 字节的请求同时
// 上传到上限 10 字节的账号，只能成功一个，另一个拿到 413 storage_full 用的
// StorageFullError；已用量停在 6，不会因为同时通过检查而写超。
func TestServicePutQuotaIsAtomic(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewStore(objectstore.NewMemory()), 1<<20).SetAccountBytes(10)
	shaA := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	shaB := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

	var wg sync.WaitGroup
	start := make(chan struct{})
	errs := make([]error, 2)
	shas := []string{shaA, shaB}
	for i := range 2 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			data := bytes.Repeat([]byte("ab"), 3)
			<-start
			errs[i] = svc.Put(ctx, "u1", shas[i], int64(len(data)), bytes.NewReader(data))
		}(i)
	}
	close(start)
	wg.Wait()

	var full *StorageFullError
	okCount := 0
	for _, err := range errs {
		switch {
		case err == nil:
			okCount++
		case errors.As(err, &full):
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if okCount != 1 {
		t.Fatalf("exactly one upload must succeed, got %d (errs %v)", okCount, errs)
	}
	used, err := svc.store.Used(ctx, "u1")
	if err != nil || used != 6 {
		t.Fatalf("used = %d, %v", used, err)
	}
}

// TestServicePutDuplicateSHADoesNotDoubleCount 守住按内容寻址的计费：同一份内容
// 上传两次只占一份配额；账号之间互不影响，一个账号满了另一个还能写。
func TestServicePutDuplicateSHADoesNotDoubleCount(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewStore(objectstore.NewMemory()), 1<<20).SetAccountBytes(10)
	data := bytes.Repeat([]byte("x"), 6)

	for range 2 {
		if err := svc.Put(ctx, "u1", shaA, int64(len(data)), bytes.NewReader(data)); err != nil {
			t.Fatalf("duplicate put: %v", err)
		}
	}
	if used, err := svc.store.Used(ctx, "u1"); err != nil || used != 6 {
		t.Fatalf("duplicate sha was double counted: used %d, %v", used, err)
	}
	if err := svc.Put(ctx, "u1", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 5, bytes.NewReader(bytes.Repeat([]byte("y"), 5))); !errors.Is(err, ErrStorageFull) {
		t.Fatalf("account over limit: want ErrStorageFull, got %v", err)
	}
	if err := svc.Put(ctx, "u2", shaA, int64(len(data)), bytes.NewReader(data)); err != nil {
		t.Fatalf("another account must not be limited: %v", err)
	}
}
