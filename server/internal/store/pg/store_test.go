package pg

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// newTestStore 连一个真实的 PostgreSQL 并整份建表。
//
// CI 提供临时 PostgreSQL，开发机可设置 ZHIXIN_TEST_DATABASE_URL。
// 连接串必须指向专用测试库，因为用例会删除其中的业务表。
func newTestStore(t *testing.T) *Store {
	t.Helper()
	return newTestStoreWith(t, objectstore.NewMemory())
}

// newTestStoreWith 与 newTestStore 相同，只是允许用例换一种对象存储实现：
// 核对目录存储的键边界时要看到真实的路径归一化。
func newTestStoreWith(t *testing.T, objects objectstore.Store) *Store {
	t.Helper()
	dsn := strings.TrimSpace(os.Getenv("ZHIXIN_TEST_DATABASE_URL"))
	if dsn == "" {
		t.Skip("未设置 ZHIXIN_TEST_DATABASE_URL，跳过 PostgreSQL 用例")
	}
	ctx := context.Background()
	st, err := Open(ctx, dsn, Options{Objects: objects})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(st.Close)
	// 开发阶段不写迁移：先删后建，保证从当前 schema.sql 起步（ADR-0001）。
	drop := `DROP TABLE IF EXISTS llm_quota, install_active, user_active, feedback, llm_usage, backup, sync_commit, sync_head, auth_code, session, app_user CASCADE`
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

	now := time.Now().UTC().Truncate(time.Microsecond)
	code := auth.Code{
		UserID: u.ID, Purpose: auth.PurposeVerifyEmail, CodeHash: "hash-1",
		ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}
	if err := st.PutCode(ctx, code); err != nil {
		t.Fatalf("put code: %v", err)
	}
	gotCode, err := st.Code(ctx, u.ID, auth.PurposeVerifyEmail)
	if err != nil || gotCode.CodeHash != "hash-1" || gotCode.Attempts != 0 {
		t.Fatalf("get code: %v %+v", err, gotCode)
	}
	if n, err := st.IncrementCodeAttempts(ctx, u.ID, auth.PurposeVerifyEmail); err != nil || n != 1 {
		t.Fatalf("increment attempts: %v %d", err, n)
	}
	if err := st.SetEmailVerified(ctx, u.ID, now); err != nil {
		t.Fatalf("set verified: %v", err)
	}
	verified, err := st.UserByID(ctx, u.ID)
	if err != nil || verified.EmailVerifiedAt.IsZero() {
		t.Fatalf("verified user: %v %+v", err, verified)
	}
	if err := st.UpdatePassword(ctx, u.ID, "hash-2"); err != nil {
		t.Fatalf("update password: %v", err)
	}
	if err := st.DeleteCode(ctx, u.ID, auth.PurposeVerifyEmail); err != nil {
		t.Fatalf("delete code: %v", err)
	}
	if _, err := st.Code(ctx, u.ID, auth.PurposeVerifyEmail); err != auth.ErrNotFound {
		t.Fatalf("code survived delete: %v", err)
	}
	if err := st.DeleteUserSessions(ctx, u.ID); err != nil {
		t.Fatalf("delete sessions: %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah"); err != auth.ErrNotFound {
		t.Fatalf("session survived: %v", err)
	}
	// 删会话之后再建一条，供下面核对账号级联删除。
	sess2 := sess
	sess2.ID, sess2.AccessHash, sess2.RefreshHash = "s2", "ah2", "rh2"
	if err := st.CreateSession(ctx, sess2); err != nil {
		t.Fatalf("create second session: %v", err)
	}
	// 会话随账号行级联删除（schema.sql 的 ON DELETE CASCADE），服务层不再单独
	// 调一次删会话。
	if err := st.DeleteUser(ctx, u.ID); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "rh2"); err != auth.ErrNotFound {
		t.Fatalf("清掉账号之后应找不到会话，得到 %v", err)
	}
}

func TestPostgresDeleteUserAndObjects(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "a@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}
	body := []byte("zip-b1")
	meta := backup.Meta{
		ID: "b1", SHA256: "sha-b1", Size: int64(len(body)), SchemaVersion: 26,
		DeviceName: "phone", CreatedAt: time.Now().UTC(),
	}
	if err := st.Put(ctx, "u1", meta, bytes.NewReader(body), 5); err != nil {
		t.Fatalf("put: %v", err)
	}

	// 账号行删除可以重试；对象字节由独立的清理步骤负责，两步之间不会互相
	// 依赖，因此任何一步失败都能从头再来。
	for i := 0; i < 2; i++ {
		if err := st.DeleteUser(ctx, "u1"); err != nil {
			t.Fatalf("第 %d 次删除账号失败: %v", i+1, err)
		}
	}
	if _, err := st.UserByID(ctx, "u1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("账号应已删除，得到 %v", err)
	}
	if err := st.DeleteUserObjects(ctx, "u1"); err != nil {
		t.Fatalf("delete objects: %v", err)
	}
	if _, err := st.objects.Stat(ctx, objectstore.BackupKey("u1", "b1")); !errors.Is(err, objectstore.ErrNotFound) {
		t.Fatalf("备份字节应随账号清理，得到 %v", err)
	}
}

// TestPostgresClearAccountData 覆盖“保留账号、清空云端数据”的两个存储方法：
// 清空备份删掉元数据行与对象字节，清空序列把 head 归零；两者都只影响指定账号，
// 清空之后可以继续上传与推送，空账号重复清空也成功。
func TestPostgresClearAccountData(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, id := range []string{"u1", "u2"} {
		if err := st.CreateUser(ctx, auth.User{ID: id, Email: id + "@b.cn", PasswordHash: "h"}); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	put := func(userID, id, body string) {
		t.Helper()
		meta := backup.Meta{
			ID: id, SHA256: "sha-" + id, Size: int64(len(body)), SchemaVersion: 27,
			CreatedAt: time.Now().UTC(),
		}
		if err := st.Put(ctx, userID, meta, strings.NewReader(body), 5); err != nil {
			t.Fatalf("put %s/%s: %v", userID, id, err)
		}
	}
	put("u1", "b1", "zip-b1")
	put("u1", "b2", "zip-b2")
	put("u2", "b9", "zip-b9")

	if err := st.DeleteAll(ctx, "u1"); err != nil {
		t.Fatalf("delete all backups: %v", err)
	}
	if list, err := st.List(ctx, "u1"); err != nil || len(list) != 0 {
		t.Fatalf("backups after clear = %+v, %v", list, err)
	}
	for _, id := range []string{"b1", "b2"} {
		if _, err := st.objects.Stat(ctx, objectstore.BackupKey("u1", id)); !errors.Is(err, objectstore.ErrNotFound) {
			t.Fatalf("对象 %s 应随清空删除，得到 %v", id, err)
		}
	}
	if list, err := st.List(ctx, "u2"); err != nil || len(list) != 1 || list[0].ID != "b9" {
		t.Fatalf("另一个账号的备份应保留，得到 %+v, %v", list, err)
	}

	mk := func(id string) syncsvc.Commit {
		after := json.RawMessage(`{}`)
		return syncsvc.Commit{
			RequestId: id, DeviceId: "d1", SchemaVersion: 27,
			Actor: "user", Action: "write", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	if head, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1"), mk("r2")}); err != nil || head != 2 {
		t.Fatalf("append u1: head %d, err %v", head, err)
	}
	if head, err := st.Append(ctx, "u2", 0, []syncsvc.Commit{mk("other")}); err != nil || head != 1 {
		t.Fatalf("append u2: head %d, err %v", head, err)
	}

	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if head, err := st.Head(ctx, "u1"); err != nil || head != 0 {
		t.Fatalf("head after reset = %d, %v", head, err)
	}
	if commits, err := st.After(ctx, "u1", 0, 10); err != nil || len(commits) != 0 {
		t.Fatalf("commits after reset = %+v, %v", commits, err)
	}
	// 重置之后从 0 重新推送，序号重新从 1 开始。
	if head, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r3")}); err != nil || head != 1 {
		t.Fatalf("append after reset: head %d, err %v", head, err)
	}
	if head, err := st.Head(ctx, "u2"); err != nil || head != 1 {
		t.Fatalf("另一个账号的 head 应保留，得到 %d, %v", head, err)
	}

	// 已经清空的账号重复清空也成功，失败重试不需要先判断有没有数据。
	if err := st.DeleteAll(ctx, "u1"); err != nil {
		t.Fatalf("second delete all: %v", err)
	}
	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("second reset: %v", err)
	}
}

// seedBackup 建一个账号并写一份备份；用例只关心归属与对象键。
func seedBackup(t *testing.T, st *Store, userID, email, id string) {
	t.Helper()
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: userID, Email: email, PasswordHash: "h"}); err != nil {
		t.Fatalf("user %s: %v", userID, err)
	}
	body := []byte("zip-" + id)
	meta := backup.Meta{
		ID: id, SHA256: "sha-" + id, Size: int64(len(body)), SchemaVersion: 27,
		CreatedAt: time.Now().UTC(),
	}
	if err := st.Put(ctx, userID, meta, bytes.NewReader(body), 5); err != nil {
		t.Fatalf("put %s/%s: %v", userID, id, err)
	}
}

// TestPostgresBackupDeleteScopesToAccount 守住删除的归属：拿另一个账号的 id 删除
// 停在 ErrNotFound，元数据与对象都不动；0 行时不会按 id 拼出的键去删对象。
func TestPostgresBackupDeleteScopesToAccount(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	seedBackup(t, st, "u1", "a@b.cn", "mine")
	seedBackup(t, st, "u2", "c@d.cn", "other")

	if err := st.Delete(ctx, "u1", "other"); !errors.Is(err, backup.ErrNotFound) {
		t.Fatalf("cross-account delete: want ErrNotFound, got %v", err)
	}
	if _, err := st.objects.Stat(ctx, objectstore.BackupKey("u2", "other")); err != nil {
		t.Fatalf("another account's object must stay: %v", err)
	}
	if list, err := st.List(ctx, "u2"); err != nil || len(list) != 1 {
		t.Fatalf("another account's metadata must stay: %+v, %v", list, err)
	}

	// 形状像 ../u2/other 的 id：删不到行，也就不会去碰 u2 的对象。
	if err := st.Delete(ctx, "u1", "../u2/other"); !errors.Is(err, backup.ErrNotFound) {
		t.Fatalf("path-shaped id: want ErrNotFound, got %v", err)
	}
	if _, err := st.objects.Stat(ctx, objectstore.BackupKey("u2", "other")); err != nil {
		t.Fatalf("path-shaped id touched another account: %v", err)
	}

	// 自己的能删一次，第二次停在 ErrNotFound。
	if err := st.Delete(ctx, "u1", "mine"); err != nil {
		t.Fatalf("delete own backup: %v", err)
	}
	if _, err := st.objects.Stat(ctx, objectstore.BackupKey("u1", "mine")); !errors.Is(err, objectstore.ErrNotFound) {
		t.Fatalf("own object should be deleted, got %v", err)
	}
	if err := st.Delete(ctx, "u1", "mine"); !errors.Is(err, backup.ErrNotFound) {
		t.Fatalf("second delete: want ErrNotFound, got %v", err)
	}
}

// TestPostgresBackupDeleteDoesNotEscapeDirStore 用目录存储核对 ../ 形状的 id：
// 目录实现会把 backups/u1/../u2/target.zip 归一成另一个账号的路径；服务层的
// id 校验之外，存储层“0 行不动对象”是第二道保险。
func TestPostgresBackupDeleteDoesNotEscapeDirStore(t *testing.T) {
	dir, err := objectstore.NewDir(t.TempDir())
	if err != nil {
		t.Fatalf("dir: %v", err)
	}
	st := newTestStoreWith(t, dir)
	ctx := context.Background()
	seedBackup(t, st, "u1", "a@b.cn", "mine")
	seedBackup(t, st, "u2", "c@d.cn", "target")

	if err := st.Delete(ctx, "u1", "../u2/target"); !errors.Is(err, backup.ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	if _, err := dir.Stat(ctx, objectstore.BackupKey("u2", "target")); err != nil {
		t.Fatalf("another account's object was deleted through a path-shaped id: %v", err)
	}
}

// TestPostgresDeleteAllClearsLeftoverObjects 守住清空备份的最后一步：元数据已经
// 不在、对象还留着的孤儿会被账号前缀清理删掉，另一个账号不受影响。
func TestPostgresDeleteAllClearsLeftoverObjects(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	seedBackup(t, st, "u1", "a@b.cn", "b1")
	seedBackup(t, st, "u2", "c@d.cn", "b2")

	orphan := objectstore.BackupKey("u1", "orphan")
	body := []byte("left-behind")
	if err := st.objects.Put(ctx, orphan, bytes.NewReader(body), objectstore.Info{Size: int64(len(body))}); err != nil {
		t.Fatalf("seed orphan: %v", err)
	}

	if err := st.DeleteAll(ctx, "u1"); err != nil {
		t.Fatalf("delete all: %v", err)
	}
	if _, err := st.objects.Stat(ctx, orphan); !errors.Is(err, objectstore.ErrNotFound) {
		t.Fatalf("leftover object should be removed, got %v", err)
	}
	if list, err := st.List(ctx, "u1"); err != nil || len(list) != 0 {
		t.Fatalf("metadata after clear = %+v, %v", list, err)
	}
	if _, err := st.objects.Stat(ctx, objectstore.BackupKey("u2", "b2")); err != nil {
		t.Fatalf("another account's object must stay: %v", err)
	}
}

// TestPostgresBlobQuota 覆盖附件索引的配额语义：重复内容不重复计数、超限带
// 已用量与上限、保存失败回滚但字节已存在时保留索引、账号间互不影响、回填幂等、
// 清账号与删账号都清掉索引与字节。
func TestPostgresBlobQuota(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	bs := NewBlobStore(st)
	for _, id := range []string{"u1", "u2"} {
		if err := st.CreateUser(ctx, auth.User{ID: id, Email: id + "@b.cn", PasswordHash: "h"}); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	shaC := strings.Repeat("c", 64)

	if used, err := bs.Reserve(ctx, "u1", shaA, 4, 10); err != nil || used != 4 {
		t.Fatalf("first reserve: used %d, err %v", used, err)
	}
	if used, err := bs.Reserve(ctx, "u1", shaA, 4, 10); err != nil || used != 4 {
		t.Fatalf("duplicate reserve: used %d, err %v", used, err)
	}
	used, err := bs.Reserve(ctx, "u1", shaB, 7, 10)
	var full *blobs.StorageFullError
	if !errors.Is(err, blobs.ErrStorageFull) || !errors.As(err, &full) || used != 4 || full.Used != 4 || full.Limit != 10 {
		t.Fatalf("over limit: used %d, err %v", used, err)
	}

	// 保存之后字节可读；模拟一次失败重传触发 Release，字节还在时索引不动。
	body := []byte("four")
	if err := bs.Save(ctx, "u1", shaA, int64(len(body)), bytes.NewReader(body)); err != nil {
		t.Fatalf("save: %v", err)
	}
	if size, err := bs.Stat(ctx, "u1", shaA); err != nil || size != int64(len(body)) {
		t.Fatalf("stat = %d, %v", size, err)
	}
	rc, _, err := bs.Open(ctx, "u1", shaA)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	got, _ := io.ReadAll(rc)
	_ = rc.Close()
	if !bytes.Equal(got, body) {
		t.Fatalf("open content = %q", got)
	}
	if err := bs.Release(ctx, "u1", shaA, int64(len(body))); err != nil {
		t.Fatalf("release: %v", err)
	}
	if used, err := bs.Used(ctx, "u1"); err != nil || used != 4 {
		t.Fatalf("release removed the index while bytes exist: used %d, %v", used, err)
	}

	// 另一个账号的总量单独计算。
	if used, err := bs.Reserve(ctx, "u2", shaA, 4, 10); err != nil || used != 4 {
		t.Fatalf("other account reserve: used %d, err %v", used, err)
	}

	// 回填：对象已经在存储里、索引没有时补一行，幂等。
	orphan := []byte("five!")
	if err := st.objects.Put(ctx, objectstore.AttachmentKey("u1", shaC), bytes.NewReader(orphan),
		objectstore.Info{Size: int64(len(orphan))}); err != nil {
		t.Fatalf("seed object: %v", err)
	}
	if added, err := bs.BackfillAttachment(ctx, "u1", shaC, int64(len(orphan))); err != nil || !added {
		t.Fatalf("backfill: added %v, err %v", added, err)
	}
	if added, err := bs.BackfillAttachment(ctx, "u1", shaC, int64(len(orphan))); err != nil || added {
		t.Fatalf("second backfill must be a no-op: added %v, err %v", added, err)
	}
	if used, err := bs.Used(ctx, "u1"); err != nil || used != 4+int64(len(orphan)) {
		t.Fatalf("used after backfill = %d, %v", used, err)
	}

	// 清账号（保留账号行）删索引与字节。
	if err := bs.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("delete attachments: %v", err)
	}
	if used, err := bs.Used(ctx, "u1"); err != nil || used != 0 {
		t.Fatalf("used after clear = %d, %v", used, err)
	}
	if _, err := bs.Stat(ctx, "u1", shaA); !errors.Is(err, blobs.ErrNotFound) {
		t.Fatalf("bytes after clear: %v", err)
	}

	// 删账号时 attachment 行按外键级联删除。
	if err := st.DeleteUser(ctx, "u2"); err != nil {
		t.Fatalf("delete account: %v", err)
	}
	var rows int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM attachment`).Scan(&rows); err != nil {
		t.Fatalf("count attachment: %v", err)
	}
	if rows != 0 {
		t.Fatalf("attachment rows should cascade with the account, got %d", rows)
	}
}

// TestPostgresBlobReserveIsSerialized 核对同一账号的并发预留：两个各 6 字节的
// 预留同时进入事务，账号行锁让它们排队，只有一个通过上限 10 的检查。
func TestPostgresBlobReserveIsSerialized(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	bs := NewBlobStore(st)
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "a@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}

	var wg sync.WaitGroup
	start := make(chan struct{})
	errs := make([]error, 2)
	shas := []string{strings.Repeat("a", 64), strings.Repeat("b", 64)}
	for i := range 2 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, errs[i] = bs.Reserve(ctx, "u1", shas[i], 6, 10)
		}(i)
	}
	close(start)
	wg.Wait()

	okCount := 0
	for _, err := range errs {
		var full *blobs.StorageFullError
		switch {
		case err == nil:
			okCount++
		case errors.As(err, &full):
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if okCount != 1 {
		t.Fatalf("exactly one reservation must succeed, got %d (%v)", okCount, errs)
	}
	if used, err := bs.Used(ctx, "u1"); err != nil || used != 6 {
		t.Fatalf("used = %d, %v", used, err)
	}
}

// TestPostgresPurgeMarker 核对清除标记的存储语义：没有标记、取得后拒绝新请求
// 覆盖、超过有效期可接管、结束时删除；删账号时标记按外键级联删除。
func TestPostgresPurgeMarker(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "a@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}

	if _, ok, err := st.PurgeStartedAt(ctx, "u1"); err != nil || ok {
		t.Fatalf("marker before purge: ok=%v err=%v", ok, err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	claimed, err := st.ClaimPurge(ctx, "u1", now, now.Add(-cloudpurge.StaleAfter))
	if err != nil || !claimed {
		t.Fatalf("claim: claimed %v, err %v", claimed, err)
	}
	started, ok, err := st.PurgeStartedAt(ctx, "u1")
	if err != nil || !ok || !started.Equal(now) {
		t.Fatalf("marker = %v, ok %v, err %v", started, ok, err)
	}
	// 标记还新：第二次取得被拒绝。
	if claimed, err := st.ClaimPurge(ctx, "u1", now.Add(time.Minute), now.Add(time.Minute-cloudpurge.StaleAfter)); err != nil || claimed {
		t.Fatalf("fresh marker must reject a second claim: claimed %v, err %v", claimed, err)
	}
	// 超过有效期：接管并刷新时间。
	later := now.Add(cloudpurge.StaleAfter + time.Minute)
	if claimed, err := st.ClaimPurge(ctx, "u1", later, later.Add(-cloudpurge.StaleAfter)); err != nil || !claimed {
		t.Fatalf("stale marker takeover: claimed %v, err %v", claimed, err)
	}
	if started, _, _ := st.PurgeStartedAt(ctx, "u1"); !started.Equal(later) {
		t.Fatalf("marker after takeover = %v, want %v", started, later)
	}

	// 结束时删除标记。
	if err := st.EndPurge(ctx, "u1"); err != nil {
		t.Fatalf("end purge: %v", err)
	}
	if _, ok, err := st.PurgeStartedAt(ctx, "u1"); err != nil || ok {
		t.Fatalf("marker after end: ok=%v err=%v", ok, err)
	}

	// 删账号时标记级联删除，不会留下指向不存在账号的行。
	if _, err := st.ClaimPurge(ctx, "u1", later, later.Add(-cloudpurge.StaleAfter)); err != nil {
		t.Fatalf("claim before account deletion: %v", err)
	}
	if err := st.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("delete account: %v", err)
	}
	var rows int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM user_purge`).Scan(&rows); err != nil {
		t.Fatalf("count user_purge: %v", err)
	}
	if rows != 0 {
		t.Fatalf("user_purge rows should cascade with the account, got %d", rows)
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
		after := json.RawMessage(`{}`)
		return syncsvc.Commit{
			RequestId: id, DeviceId: "d1", SchemaVersion: 26,
			Actor: "user", Action: "写入", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
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
	if commits[0].Seq == nil || *commits[0].Seq != 1 || commits[0].RequestId != "r1" || len(commits[0].Changes) != 1 {
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

// TestPostgresFeedback 核对反馈落库的字段：正文、联系邮箱、版本、平台与诊断
// 摘要原样保存，时间不是零值。反馈不关联账号，因此删号用例不涉及这张表。
func TestPostgresFeedback(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	created := time.Now().UTC().Truncate(time.Microsecond)
	item := feedback.Item{
		ID: "f1", Content: "记录页没有反应", Contact: "a@b.cn",
		AppVersion: "0.2.0-dev+3", Platform: "android",
		Diagnostics: "2026-11-18 10:00 记录页", CreatedAt: created,
	}
	if err := st.CreateFeedback(ctx, item); err != nil {
		t.Fatalf("create feedback: %v", err)
	}

	var got feedback.Item
	err := st.pool.QueryRow(ctx, `SELECT id, content, contact, app_version, platform, diagnostics, created_at FROM feedback WHERE id = $1`, item.ID).
		Scan(&got.ID, &got.Content, &got.Contact, &got.AppVersion, &got.Platform, &got.Diagnostics, &got.CreatedAt)
	if err != nil {
		t.Fatalf("read feedback: %v", err)
	}
	if got.Content != item.Content || got.Contact != item.Contact ||
		got.AppVersion != item.AppVersion || got.Platform != item.Platform ||
		got.Diagnostics != item.Diagnostics {
		t.Fatalf("字段没有原样保存：%+v", got)
	}
	if !got.CreatedAt.Equal(created) {
		t.Fatalf("保存时间不对：%v vs %v", got.CreatedAt, created)
	}

	if err := st.CreateFeedback(ctx, feedback.Item{ID: "f2", Content: "x"}); err == nil {
		t.Fatal("零值时间应当报错，不能静默写成 0001-01-01")
	}
}

// TestPostgresRetention 核对活跃数据按天幂等、保留期之外的行会被清理，以及
// 登录账号的活跃随删号级联删除。
func TestPostgresRetention(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "active@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}

	for i := 0; i < 2; i++ {
		if err := st.MarkUserActive(ctx, "u1", "2026-11-18"); err != nil {
			t.Fatalf("mark user active %d: %v", i+1, err)
		}
		if err := st.MarkInstallActive(ctx, "hash-1", "2026-11-18", "0.2.0", "android"); err != nil {
			t.Fatalf("mark install active %d: %v", i+1, err)
		}
	}
	if err := st.MarkInstallActive(ctx, "hash-old", "2026-01-01", "", ""); err != nil {
		t.Fatalf("seed old install: %v", err)
	}

	var users, installs int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM user_active WHERE user_id = 'u1'`).Scan(&users); err != nil {
		t.Fatalf("count user_active: %v", err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM install_active`).Scan(&installs); err != nil {
		t.Fatalf("count install_active: %v", err)
	}
	if users != 1 {
		t.Fatalf("同一账号同一天应只有一行，得到 %d", users)
	}
	if installs != 2 {
		t.Fatalf("两个不同安装标识应各留一行，重复上报不新增，得到 %d", installs)
	}

	if err := st.PruneInstallsBefore(ctx, "2026-05-22"); err != nil {
		t.Fatalf("prune: %v", err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM install_active`).Scan(&installs); err != nil {
		t.Fatalf("count after prune: %v", err)
	}
	if installs != 1 {
		t.Fatalf("保留期外的一行应被删除，留下 1 行，得到 %d", installs)
	}

	if err := st.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM user_active`).Scan(&users); err != nil {
		t.Fatalf("count after delete: %v", err)
	}
	if users != 0 {
		t.Fatalf("删号之后活跃行应级联删除，剩下 %d", users)
	}
}

// TestPostgresQuotaOverride 核对按账号调整的额度读得到、没有行时用默认值，
// 删号时覆盖行随外键级联删除。
func TestPostgresQuotaOverride(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "quota@b.cn", PasswordHash: "h"}); err != nil {
		t.Fatalf("user: %v", err)
	}
	if _, ok, err := st.DailyLimit(ctx, "u1"); err != nil || ok {
		t.Fatalf("没有覆盖行时应回落到默认值：ok=%v err=%v", ok, err)
	}

	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_quota (user_id, daily_tokens, note) VALUES ('u1', 5000, '内测')`); err != nil {
		t.Fatalf("insert override: %v", err)
	}
	limit, ok, err := st.DailyLimit(ctx, "u1")
	if err != nil || !ok || limit != 5000 {
		t.Fatalf("覆盖额度没有读到：limit=%d ok=%v err=%v", limit, ok, err)
	}

	if err := st.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	var rows int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM llm_quota`).Scan(&rows); err != nil {
		t.Fatalf("count llm_quota: %v", err)
	}
	if rows != 0 {
		t.Fatalf("删号之后覆盖行应级联删除，剩下 %d", rows)
	}
}

// TestPgDateRequiresISODay 守住自然日只有一种写法：写错的日期必须报错，不能
// 悄悄落成零值让用量看上去像 0。
func TestPgDateRequiresISODay(t *testing.T) {
	for _, day := range []string{"", "2026-11-15T00:00:00Z", "15/11/2026", "2026-13-01"} {
		if _, err := pgDate(day); err == nil {
			t.Errorf("pgDate(%q) 应当报错", day)
		}
	}
	got, err := pgDate("2026-11-15")
	if err != nil {
		t.Fatalf("pgDate: %v", err)
	}
	if !got.Valid || got.Time.Format("2006-01-02") != "2026-11-15" {
		t.Fatalf("pgDate = %+v", got)
	}
}

// TestPgTimeRejectsZero 守住时间字段不留隐式兜底：零值说明调用方漏了赋值。
func TestPgTimeRejectsZero(t *testing.T) {
	if _, err := pgTime(time.Time{}); err == nil {
		t.Fatal("零值时间应当报错")
	}
	at := time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC)
	got, err := pgTime(at)
	if err != nil {
		t.Fatalf("pgTime: %v", err)
	}
	if !got.Valid || !got.Time.Equal(at) {
		t.Fatalf("pgTime = %+v", got)
	}
}
