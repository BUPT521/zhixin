package pg

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
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
	if err := st.CreateSession(ctx, sess, 20); err != nil {
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
	if err := st.CreateSession(ctx, sess2, 20); err != nil {
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

// TestPostgresSessionLimit 核对会话上限在事务里生效：超过上限时删最旧的一条，
// 记录条数与“删掉的是最早那条”都对得上。
func TestPostgresSessionLimit(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	u := auth.User{ID: "u1", Email: "sessions@b.cn", PasswordHash: "h"}
	if err := st.CreateUser(ctx, u); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now().UTC()
	for i := 0; i < 3; i++ {
		sess := auth.Session{
			ID:             fmt.Sprintf("s%d", i),
			UserID:         u.ID,
			AccessHash:     fmt.Sprintf("ah%d", i),
			RefreshHash:    fmt.Sprintf("rh%d", i),
			AccessExpires:  now.Add(time.Hour),
			RefreshExpires: now.Add(24 * time.Hour),
		}
		if err := st.CreateSession(ctx, sess, 2); err != nil {
			t.Fatalf("第 %d 条会话: %v", i+1, err)
		}
	}
	var count int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM session WHERE user_id = 'u1'`).Scan(&count); err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if count != 2 {
		t.Fatalf("上限 2 时应保留 2 条会话，得到 %d", count)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah0"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("最早的一条应被删掉，得到 %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah2"); err != nil {
		t.Fatalf("最新的会话应保留，得到 %v", err)
	}
}

// TestPostgresRefreshRotation 核对 CAS 轮换只有一个成功、旧令牌摘要能读回，
// 并且记录随会话删除级联消失。
func TestPostgresRefreshRotation(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	u := auth.User{ID: "u1", Email: "rotate@b.cn", PasswordHash: "h"}
	if err := st.CreateUser(ctx, u); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	sess := auth.Session{
		ID: "s1", UserID: u.ID,
		AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires:  now.Add(time.Hour),
		RefreshExpires: now.Add(24 * time.Hour),
	}
	if err := st.CreateSession(ctx, sess, 20); err != nil {
		t.Fatalf("session: %v", err)
	}

	if err := st.RotateSession(ctx, "s1", "rh1", "ah2", "rh2", now.Add(2*time.Hour), now.Add(48*time.Hour)); err != nil {
		t.Fatalf("第一次轮换: %v", err)
	}
	// 用同一个旧摘要再轮换（并发输家）应当返回 ErrInvalidToken。
	if err := st.RotateSession(ctx, "s1", "rh1", "ah3", "rh3", now.Add(3*time.Hour), now.Add(72*time.Hour)); !errors.Is(err, auth.ErrInvalidToken) {
		t.Fatalf("旧摘要再轮换应返回 ErrInvalidToken，得到 %v", err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "rh2"); err != nil {
		t.Fatalf("轮换后的刷新摘要应能查到: %v", err)
	}

	used := auth.RefreshUsed{
		TokenHash: "rh1", SessionID: "s1", UserID: u.ID, RequestID: "req-1",
		RotatedAt: now, GraceUntil: now.Add(time.Minute),
		ReplacedAccessHash: "ah2", ReplacedRefreshHash: "rh2",
	}
	// 同一个摘要重复写入是并发重试的常态，应当忽略而不是报主键冲突。
	for i := 0; i < 2; i++ {
		if err := st.RecordRefreshUsed(ctx, used); err != nil {
			t.Fatalf("第 %d 次记录旧令牌: %v", i+1, err)
		}
	}
	got, err := st.UsedRefresh(ctx, "rh1")
	if err != nil {
		t.Fatalf("读取旧令牌记录: %v", err)
	}
	if got.RequestID != "req-1" || got.SessionID != "s1" || got.ReplacedRefreshHash != "rh2" {
		t.Fatalf("旧令牌记录不符合预期: %+v", got)
	}
	if !got.GraceUntil.Equal(used.GraceUntil) {
		t.Fatalf("宽限截止时间应原样保存：%v vs %v", got.GraceUntil, used.GraceUntil)
	}

	if err := st.DeleteSession(ctx, "s1"); err != nil {
		t.Fatalf("delete session: %v", err)
	}
	if _, err := st.UsedRefresh(ctx, "rh1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("会话删除之后旧令牌记录应级联消失，得到 %v", err)
	}
}

// TestPostgresPruneExpired 核对过期会话与过期验证码会被清理，未过期的不动。
func TestPostgresPruneExpired(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	u := auth.User{ID: "u1", Email: "prune@b.cn", PasswordHash: "h"}
	if err := st.CreateUser(ctx, u); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now().UTC()
	sess := auth.Session{
		ID: "s1", UserID: u.ID,
		AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires:  now.Add(time.Hour),
		RefreshExpires: now.Add(24 * time.Hour),
	}
	if err := st.CreateSession(ctx, sess, 20); err != nil {
		t.Fatalf("session: %v", err)
	}
	// 把这条会话与两枚验证码分别改成过期与未过期，清理之后只留下未过期的。
	if _, err := st.pool.Exec(ctx, `UPDATE session SET refresh_expires = $1 WHERE id = 's1'`, now.Add(-time.Hour)); err != nil {
		t.Fatalf("expire session: %v", err)
	}
	for _, userID := range []string{u.ID, "u2"} {
		if userID == "u2" {
			if err := st.CreateUser(ctx, auth.User{ID: "u2", Email: "keep@b.cn", PasswordHash: "h"}); err != nil {
				t.Fatalf("second user: %v", err)
			}
		}
		expires := now.Add(-time.Minute)
		if userID == "u2" {
			expires = now.Add(10 * time.Minute)
		}
		if err := st.PutCode(ctx, auth.Code{
			UserID: userID, Purpose: auth.PurposeResetPassword, CodeHash: "hash-" + userID,
			ExpiresAt: expires, CreatedAt: now.Add(-time.Hour),
		}); err != nil {
			t.Fatalf("code %s: %v", userID, err)
		}
	}

	if err := st.PruneExpired(ctx, now); err != nil {
		t.Fatalf("prune: %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("过期会话应被清理，得到 %v", err)
	}
	if _, err := st.Code(ctx, u.ID, auth.PurposeResetPassword); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("过期验证码应被清理，得到 %v", err)
	}
	if _, err := st.Code(ctx, "u2", auth.PurposeResetPassword); err != nil {
		t.Fatalf("未过期验证码应保留，得到 %v", err)
	}
}

// TestPostgresDeleteUserAndObjects 检查删号之后对象字节由独立步骤清理。
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
