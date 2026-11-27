package pg

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// TestPostgresPutRejectsInvalidKeep 守住与内存实现相同的保留份数边界：keep 小于 1
// 时返回 ErrKeep，不把它解释成“不裁剪”。
func TestPostgresPutRejectsInvalidKeep(t *testing.T) {
	st := newTestStore(t)
	err := st.Put(context.Background(), "u1", backup.Meta{}, strings.NewReader("x"), 0)
	if !errors.Is(err, backup.ErrKeep) {
		t.Fatalf("keep=0: want ErrKeep, got %v", err)
	}
}

// TestPostgresListAllKeys 核对 ListAllKeys 把数据库里每份备份拼成与对象存储
// 一致的对象键：多个账号的备份都在，没有备份时返回空切片，对象存储里的遗留
// 对象不会凭空出现在结果里。对账按这个结果与 backups/ 下的对象求差集。
func TestPostgresListAllKeys(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()

	keys, err := st.ListAllKeys(ctx)
	if err != nil {
		t.Fatalf("list all keys: %v", err)
	}
	if len(keys) != 0 {
		t.Fatalf("没有备份时应返回空切片，得到 %v", keys)
	}

	seedBackup(t, st, "u1", "a@b.cn", "b1")
	seedBackup(t, st, "u2", "c@d.cn", "b2")

	// 再放一个没有元数据的遗留对象：它不在数据库行里，不能出现在结果里。
	orphan := objectstore.BackupKey("u1", "orphan")
	body := []byte("left-behind")
	if err := st.objects.Put(ctx, orphan, bytes.NewReader(body), objectstore.Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("seed orphan: %v", err)
	}

	keys, err = st.ListAllKeys(ctx)
	if err != nil {
		t.Fatalf("list all keys: %v", err)
	}
	got := make(map[string]bool, len(keys))
	for _, key := range keys {
		got[key] = true
	}
	for _, want := range []string{objectstore.BackupKey("u1", "b1"), objectstore.BackupKey("u2", "b2")} {
		if !got[want] {
			t.Fatalf("ListAllKeys 缺少 %q，得到 %v", want, keys)
		}
	}
	if got[orphan] {
		t.Fatalf("没有元数据的对象不应出现在 ListAllKeys 里: %v", keys)
	}
	if len(keys) != 2 {
		t.Fatalf("ListAllKeys 应返回 2 个键，得到 %v", keys)
	}
}
