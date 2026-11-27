package objectstore

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"
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
	// 列目录：前缀下的键与写入时间都能读到，备份对账靠写入时间判断宽限期；
	// 不存在的前缀返回空切片。
	objects, err := s.List(ctx, "attachments/")
	if err != nil || len(objects) != 2 {
		t.Fatalf("List(attachments/) = %+v, %v", objects, err)
	}
	for _, obj := range objects {
		if obj.ModTime.IsZero() {
			t.Fatalf("List 返回的对象应带写入时间: %+v", obj)
		}
	}
	objects, err = s.List(ctx, "attachments/u1/")
	if err != nil || len(objects) != 1 || objects[0].Key != "attachments/u1/aa" || objects[0].ModTime.IsZero() {
		t.Fatalf("List(attachments/u1/) = %+v, %v", objects, err)
	}
	if objects, err = s.List(ctx, "missing/"); err != nil || len(objects) != 0 {
		t.Fatalf("List(missing/) = %+v, %v", objects, err)
	}
	if _, err := s.List(ctx, ""); err == nil {
		t.Fatal("List with an empty prefix must be rejected")
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

// TestObjectPrefixesAndKeysShareOneDefinition 核对键规则只有一处：前缀常量、
// 账号前缀与完整键逐层拼出来，后台对账扫描的前缀因此与写入方一致。
func TestObjectPrefixesAndKeysShareOneDefinition(t *testing.T) {
	if got, want := BackupPrefix("u1"), BackupObjectPrefix+"u1/"; got != want {
		t.Fatalf("BackupPrefix = %q，want %q", got, want)
	}
	if got, want := BackupKey("u1", "b1"), BackupPrefix("u1")+"b1.zip"; got != want {
		t.Fatalf("BackupKey = %q，want %q", got, want)
	}
	if got, want := AttachmentPrefix("u1"), AttachmentObjectPrefix+"u1/"; got != want {
		t.Fatalf("AttachmentPrefix = %q，want %q", got, want)
	}
	if got, want := AttachmentKey("u1", "aa"), AttachmentPrefix("u1")+"aa"; got != want {
		t.Fatalf("AttachmentKey = %q，want %q", got, want)
	}
	if !strings.HasPrefix(BackupKey("u1", "b1"), BackupObjectPrefix) || !strings.HasPrefix(AttachmentKey("u1", "aa"), AttachmentObjectPrefix) {
		t.Fatal("完整键必须落在对账扫描的前缀下")
	}
}

func TestMemory(t *testing.T) {
	testStore(t, func(*testing.T) Store { return NewMemory() })
}

// TestMemoryListReportsModTime 核对内存实现记录的写入时间：PutAt 原样保存调用方
// 给的时间，供备份用例构造“早先写入”的遗留对象；Put 记的是当前时间。
func TestMemoryListReportsModTime(t *testing.T) {
	ctx := context.Background()
	m := NewMemory()
	body := []byte("zip")
	at := time.Date(2026, 11, 20, 9, 30, 0, 0, time.UTC)
	if err := m.PutAt(ctx, "backups/u1/b1.zip", bytes.NewReader(body), Info{Size: int64(len(body))}, at); err != nil {
		t.Fatalf("PutAt: %v", err)
	}
	objects, err := m.List(ctx, "backups/")
	if err != nil || len(objects) != 1 || !objects[0].ModTime.Equal(at) {
		t.Fatalf("List 应原样返回 PutAt 的时间: %+v, %v", objects, err)
	}

	before := time.Now().Add(-time.Minute)
	if err := m.Put(ctx, "backups/u1/b2.zip", bytes.NewReader(body), Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	objects, err = m.List(ctx, "backups/")
	if err != nil || len(objects) != 2 {
		t.Fatalf("List = %+v, %v", objects, err)
	}
	if got := objects[1].ModTime; got.Before(before) || got.After(time.Now().Add(time.Minute)) {
		t.Fatalf("Put 应记下当前时间: %v", got)
	}
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

// TestS3ListFillsModTime 需要真实的 S3 兼容存储：设置 ZHIXIN_TEST_S3_ENDPOINT
// 等环境变量时执行，本机没有 bucket 时跳过。列目录返回的写入时间取自
// ListObjectsV2 的 LastModified，应当落在这次写入前后的区间里。
func TestS3ListFillsModTime(t *testing.T) {
	endpoint := strings.TrimSpace(os.Getenv("ZHIXIN_TEST_S3_ENDPOINT"))
	if endpoint == "" {
		t.Skip("未设置 ZHIXIN_TEST_S3_ENDPOINT，跳过 S3 用例")
	}
	s, err := NewS3(S3Config{
		Endpoint:  endpoint,
		Bucket:    os.Getenv("ZHIXIN_TEST_S3_BUCKET"),
		AccessKey: os.Getenv("ZHIXIN_TEST_S3_ACCESS_KEY"),
		SecretKey: os.Getenv("ZHIXIN_TEST_S3_SECRET_KEY"),
		Region:    os.Getenv("ZHIXIN_TEST_S3_REGION"),
		UseSSL:    os.Getenv("ZHIXIN_TEST_S3_USE_SSL") == "1",
	})
	if err != nil {
		t.Fatalf("NewS3: %v", err)
	}
	ctx := context.Background()
	prefix := fmt.Sprintf("backups/test-%d/", time.Now().UnixNano())
	key := prefix + "object.zip"
	body := []byte("s3-mod-time")
	before := time.Now().UTC().Add(-time.Minute)
	if err := s.Put(ctx, key, bytes.NewReader(body), Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	t.Cleanup(func() { _ = s.Remove(context.Background(), key) })

	objects, err := s.List(ctx, prefix)
	if err != nil || len(objects) != 1 {
		t.Fatalf("List(%q) = %+v, %v", prefix, objects, err)
	}
	after := time.Now().UTC().Add(time.Minute)
	if got := objects[0].ModTime; got.IsZero() || got.Before(before) || got.After(after) {
		t.Fatalf("List 返回的写入时间不对: %v，应在 %v 与 %v 之间", got, before, after)
	}
}

func TestS3RejectsIncompleteOptions(t *testing.T) {
	if _, err := NewS3(S3Config{Endpoint: "minio:9000", Bucket: "zhixin"}); err == nil {
		t.Fatal("missing credentials must be rejected")
	}
}
