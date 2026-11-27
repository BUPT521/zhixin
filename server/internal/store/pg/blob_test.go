package pg

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// TestPostgresBlobListAllKeys 核对附件索引的 ListAllKeys 把每行拼成与对象存储
// 一致的对象键，供备份对账比对 attachments/ 下的对象：多个账号都在，没有索引
// 的遗留对象不会出现在结果里。
func TestPostgresBlobListAllKeys(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, id := range []string{"u1", "u2"} {
		if err := createAccount(ctx, st, auth.User{ID: id, PasswordHash: "h"}, id+"@b.cn"); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}

	bs := NewBlobStore(st)
	shas := map[string]string{
		"u1": strings.Repeat("a", 64),
		"u2": strings.Repeat("b", 64),
	}
	body := []byte("four")
	for userID, sha := range shas {
		if _, err := bs.Reserve(ctx, userID, sha, int64(len(body)), 0); err != nil {
			t.Fatalf("reserve %s: %v", userID, err)
		}
		if err := bs.Save(ctx, userID, sha, int64(len(body)), bytes.NewReader(body)); err != nil {
			t.Fatalf("save %s: %v", userID, err)
		}
	}

	// 字节在、索引没有：这是对账要删的遗留对象，不能出现在结果里。
	orphan := objectstore.AttachmentKey("u1", strings.Repeat("c", 64))
	if err := st.objects.Put(ctx, orphan, bytes.NewReader(body), objectstore.Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("seed orphan: %v", err)
	}

	keys, err := bs.ListAllKeys(ctx)
	if err != nil {
		t.Fatalf("list all keys: %v", err)
	}
	got := make(map[string]bool, len(keys))
	for _, key := range keys {
		got[key] = true
	}
	for userID, sha := range shas {
		want := objectstore.AttachmentKey(userID, sha)
		if !got[want] {
			t.Fatalf("ListAllKeys 缺少 %q，得到 %v", want, keys)
		}
	}
	if got[orphan] {
		t.Fatalf("没有索引的对象不应出现在 ListAllKeys 里: %v", keys)
	}
	if len(keys) != 2 {
		t.Fatalf("ListAllKeys 应返回 2 个键，得到 %v", keys)
	}
}
