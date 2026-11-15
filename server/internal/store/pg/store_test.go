package pg

import (
	"bytes"
	"context"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// newTestStore 连一个真实的 PostgreSQL 并整份建表。
//
// CI 提供临时 PostgreSQL，开发机可设置 ZHIXIN_TEST_DATABASE_URL。
// 连接串必须指向专用测试库，因为用例会删除其中的业务表。
func newTestStore(t *testing.T) *Store {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("ZHIXIN_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("未设置 ZHIXIN_TEST_DATABASE_URL，跳过 PostgreSQL 用例")
	}
	ctx := context.Background()
	st, err := Open(ctx, dsn, Options{Objects: objectstore.NewMemory()})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(st.Close)
	// 开发阶段不写迁移：先删后建，保证从当前 schema.sql 起步（ADR-0001）。
	drop := `DROP TABLE IF EXISTS llm_usage, backup, blob, sync_commit, sync_head, session, app_user CASCADE`
	if _, err := st.pool.Exec(ctx, drop); err != nil {
		t.Fatalf("drop: %v", err)
	}
	if err := st.ApplySchema(ctx); err != nil {
		t.Fatalf("schema: %v", err)
	}
	return st
}

func TestPostgresAuthAndSessions(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()

	u := auth.User{ID: "u1", Email: "a@b.cn", PasswordHash: "hash", CreatedAt: time.Now().UTC()}
	if err := st.CreateUser(ctx, u); err != nil {
		t.Fatalf("create user: %v", err)
	}
	if err := st.CreateUser(ctx, u); err != auth.ErrEmailTaken {
		t.Fatalf("重复邮箱应返回 ErrEmailTaken，得到 %v", err)
	}
	got, err := st.UserByEmail(ctx, u.Email)
	if err != nil || got.ID != u.ID {
		t.Fatalf("by email: %v %+v", err, got)
	}
	if _, err := st.UserByID(ctx, "missing"); err != auth.ErrNotFound {
		t.Fatalf("未知账号应返回 ErrNotFound，得到 %v", err)
	}

	sess := auth.Session{
		ID: "s1", UserID: u.ID, DeviceName: "phone",
		AccessHash: "ah", RefreshHash: "rh",
		AccessExpires:  time.Now().Add(time.Hour).UTC(),
		RefreshExpires: time.Now().Add(24 * time.Hour).UTC(),
	}
	if err := st.CreateSession(ctx, sess); err != nil {
		t.Fatalf("create session: %v", err)
	}
	byAccess, err := st.SessionByAccessHash(ctx, "ah")
	if err != nil || byAccess.ID != "s1" {
		t.Fatalf("by access: %v %+v", err, byAccess)
	}
	if err := st.DeleteUserSessions(ctx, u.ID); err != nil {
		t.Fatalf("delete sessions: %v", err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "rh"); err != auth.ErrNotFound {
		t.Fatalf("清掉会话之后应找不到，得到 %v", err)
	}
}

func TestPostgresSyncSequence(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "a@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}

	head, err := st.Head(ctx, "u1")
	if err != nil || head != 0 {
		t.Fatalf("空日志 head 应为 0，得到 %d %v", head, err)
	}

	mk := func(id string) syncsvc.Commit {
		return syncsvc.Commit{
			RequestID: id, DeviceID: "d1", SchemaVersion: 26,
			Actor: "user", Action: "写入", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: []byte(`{}`)}},
		}
	}
	head, err = st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1"), mk("r2")})
	if err != nil || head != 2 {
		t.Fatalf("追加两条后 head 应为 2，得到 %d %v", head, err)
	}

	// 完全重放：base 不对也算成功，因为客户端没收到上一次响应。
	if head, err = st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1")}); err != nil || head != 2 {
		t.Fatalf("重放应成功并保持 head=2，得到 %d %v", head, err)
	}
	if head, err = st.Append(ctx, "u1", 1, []syncsvc.Commit{mk("r3")}); err != syncsvc.ErrHeadMoved || head != 2 {
		t.Fatalf("base 落后应返回 ErrHeadMoved，得到 %d %v", head, err)
	}

	commits, err := st.After(ctx, "u1", 0, 10)
	if err != nil || len(commits) != 2 {
		t.Fatalf("拉取应有两条，得到 %d %v", len(commits), err)
	}
	if commits[0].Seq != 1 || commits[0].RequestID != "r1" || len(commits[0].Changes) != 1 {
		t.Fatalf("第一条不符合预期: %+v", commits[0])
	}
}

func TestPostgresBackupsAndQuota(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "a@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}

	for _, id := range []string{"b1", "b2", "b3"} {
		body := []byte("zip-" + id)
		meta := backup.Meta{
			ID: id, SHA256: "sha-" + id, Size: int64(len(body)), SchemaVersion: 26,
			DeviceName: "phone", CreatedAt: time.Now().UTC().Add(time.Duration(len(id)) * time.Second),
		}
		if err := st.Put(ctx, "u1", meta, bytes.NewReader(body), 2); err != nil {
			t.Fatalf("put %s: %v", id, err)
		}
	}
	list, err := st.List(ctx, "u1")
	if err != nil || len(list) != 2 {
		t.Fatalf("只保留两份，得到 %d %v", len(list), err)
	}
	meta, rc, err := st.Open(ctx, "u1", list[0].ID)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	data, err := io.ReadAll(rc)
	_ = rc.Close()
	if err != nil || !strings.Contains(string(data), "zip-") {
		t.Fatalf("读回字节失败: %v %q", err, data)
	}
	if meta.Size != int64(len(data)) {
		t.Fatalf("元数据大小应与字节一致: %d vs %d", meta.Size, len(data))
	}

	if used, err := st.Used(ctx, "u1", "2026-11-15"); err != nil || used != 0 {
		t.Fatalf("未用过的日子应为 0，得到 %d %v", used, err)
	}
	if err := st.Add(ctx, "u1", "2026-11-15", 120); err != nil {
		t.Fatalf("add: %v", err)
	}
	if err := st.Add(ctx, "u1", "2026-11-15", 30); err != nil {
		t.Fatalf("add again: %v", err)
	}
	if used, err := st.Used(ctx, "u1", "2026-11-15"); err != nil || used != 150 {
		t.Fatalf("用量应累加到 150，得到 %d %v", used, err)
	}
}
