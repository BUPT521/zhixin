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
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
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
	drop := `DROP TABLE IF EXISTS embedding_cache_generation, llm_instance_usage, embedding_cache, llm_route_usage, llm_route, llm_model, llm_provider, attachment, user_purge, session_refresh_used, llm_quota, install_active, user_active, feedback, llm_usage, backup, sync_commit, sync_commit_seen, sync_ref, sync_device, sync_state, auth_code, user_identity, session, app_user CASCADE`
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

	u := auth.User{ID: "u1", PasswordHash: "hash"}
	if err := createAccount(ctx, st, u, "a@b.cn"); err != nil {
		t.Fatalf("create account: %v", err)
	}
	if err := createAccount(ctx, st, auth.User{ID: "u2", PasswordHash: "hash"}, "a@b.cn"); err != auth.ErrIdentifierTaken {
		t.Fatalf("重复登录方式应返回 ErrIdentifierTaken，得到 %v", err)
	}
	got, err := st.UserByIdentifier(ctx, auth.KindEmail, "a@b.cn")
	if err != nil || got.ID != u.ID {
		t.Fatalf("by identifier: %v %+v", err, got)
	}
	identities, err := st.Identities(ctx, u.ID)
	if err != nil || len(identities) != 1 || identities[0].Identifier != "a@b.cn" || !identities[0].VerifiedAt.IsZero() {
		t.Fatalf("identities: %v %+v", err, identities)
	}
	if _, err := st.Identity(ctx, "u2", identities[0].ID); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("别的账号读不到这条登录方式，得到 %v", err)
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
	if err := st.CreateSession(ctx, sess, 20, ""); err != nil {
		t.Fatalf("create session: %v", err)
	}
	byAccess, err := st.SessionByAccessHash(ctx, "ah")
	if err != nil || byAccess.ID != "s1" {
		t.Fatalf("by access: %v %+v", err, byAccess)
	}

	now := time.Now().UTC().Truncate(time.Microsecond)
	code := auth.Code{
		Purpose: auth.PurposeVerifyContact, Kind: auth.KindEmail, Identifier: "a@b.cn",
		UserID: u.ID, CodeHash: "hash-1",
		ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}
	if err := st.PutCode(ctx, code); err != nil {
		t.Fatalf("put code: %v", err)
	}
	gotCode, err := st.Code(ctx, auth.PurposeVerifyContact, auth.KindEmail, "a@b.cn")
	if err != nil || gotCode.CodeHash != "hash-1" || gotCode.Attempts != 0 || gotCode.UserID != u.ID {
		t.Fatalf("get code: %v %+v", err, gotCode)
	}
	if n, err := st.IncrementCodeAttempts(ctx, auth.PurposeVerifyContact, auth.KindEmail, "a@b.cn"); err != nil || n != 1 {
		t.Fatalf("increment attempts: %v %d", err, n)
	}
	if err := st.SetIdentityVerified(ctx, u.ID, identities[0].ID, now); err != nil {
		t.Fatalf("set verified: %v", err)
	}
	verified, err := st.Identity(ctx, u.ID, identities[0].ID)
	if err != nil || verified.VerifiedAt.IsZero() {
		t.Fatalf("verified identity: %v %+v", err, verified)
	}
	// “已验证”按登录方式算：确认之后按访问令牌查会话得到的 ContactVerified 为真。
	if byAccess, err := st.SessionByAccessHash(ctx, "ah"); err != nil || !byAccess.ContactVerified {
		t.Fatalf("会话上的 ContactVerified 应为真：%+v %v", byAccess, err)
	}
	if err := st.UpdatePassword(ctx, u.ID, "hash-2"); err != nil {
		t.Fatalf("update password: %v", err)
	}
	if err := st.DeleteCode(ctx, auth.PurposeVerifyContact, auth.KindEmail, "a@b.cn"); err != nil {
		t.Fatalf("delete code: %v", err)
	}
	if _, err := st.Code(ctx, auth.PurposeVerifyContact, auth.KindEmail, "a@b.cn"); err != auth.ErrNotFound {
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
	if err := st.CreateSession(ctx, sess2, 20, ""); err != nil {
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
	u := auth.User{ID: "u1", PasswordHash: "h"}
	if err := createAccount(ctx, st, u, "sessions@b.cn"); err != nil {
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
		if err := st.CreateSession(ctx, sess, 2, ""); err != nil {
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

// TestPostgresResetPassword 核对重设密码在一个事务里提交：摘要对不上时验证码
// 不被用掉、密码、登录方式与会话都不动；成功之后验证码消失、密码换掉、那种登录
// 方式标为已确认、会话清空，再用同一个验证码返回 ErrInvalidCode。
func TestPostgresResetPassword(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	u := auth.User{ID: "u1", PasswordHash: "old-hash"}
	if err := createAccount(ctx, st, u, "reset@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	identities, err := st.Identities(ctx, u.ID)
	if err != nil || len(identities) != 1 {
		t.Fatalf("identities: %v %+v", err, identities)
	}
	reset := auth.PasswordReset{
		UserID: u.ID, IdentityID: identities[0].ID,
		Purpose: auth.PurposeResetPassword, Kind: auth.KindEmail, Identifier: "reset@b.cn",
		ExpectedHash: "good", NewPasswordHash: "new-hash", Now: now,
	}
	sess := auth.Session{
		ID: "s1", UserID: u.ID,
		AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires:  now.Add(time.Hour),
		RefreshExpires: now.Add(24 * time.Hour),
	}
	if err := st.CreateSession(ctx, sess, 20, ""); err != nil {
		t.Fatalf("session: %v", err)
	}
	if err := st.PutCode(ctx, auth.Code{
		Purpose: auth.PurposeResetPassword, Kind: auth.KindEmail, Identifier: "reset@b.cn",
		UserID: u.ID, CodeHash: "good",
		ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}); err != nil {
		t.Fatalf("code: %v", err)
	}

	wrong := reset
	wrong.ExpectedHash = "wrong"
	if err := st.ResetPassword(ctx, wrong); !errors.Is(err, auth.ErrInvalidCode) {
		t.Fatalf("摘要对不上时应返回 ErrInvalidCode，得到 %v", err)
	}
	if got, err := st.UserByID(ctx, u.ID); err != nil || got.PasswordHash != "old-hash" {
		t.Fatalf("失败的原子操作不应改密码：%+v %v", got, err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah1"); err != nil {
		t.Fatalf("失败的原子操作不应删会话: %v", err)
	}
	if _, err := st.Code(ctx, auth.PurposeResetPassword, auth.KindEmail, "reset@b.cn"); err != nil {
		t.Fatalf("失败的原子操作不应吃掉验证码: %v", err)
	}

	if err := st.ResetPassword(ctx, reset); err != nil {
		t.Fatalf("正确的摘要应当成功: %v", err)
	}
	if got, err := st.UserByID(ctx, u.ID); err != nil || got.PasswordHash != "new-hash" {
		t.Fatalf("密码应换成新哈希：%+v %v", got, err)
	}
	if got, err := st.Identity(ctx, u.ID, identities[0].ID); err != nil || got.VerifiedAt.IsZero() {
		t.Fatalf("收到验证码的登录方式应标为已确认：%+v %v", got, err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("会话应被清空，得到 %v", err)
	}
	if _, err := st.Code(ctx, auth.PurposeResetPassword, auth.KindEmail, "reset@b.cn"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("验证码应被用掉，得到 %v", err)
	}
	if err := st.ResetPassword(ctx, reset); !errors.Is(err, auth.ErrInvalidCode) {
		t.Fatalf("验证码重复使用应返回 ErrInvalidCode，得到 %v", err)
	}
}

// TestPostgresRefreshRotation 核对 CAS 轮换只有一个成功、旧令牌摘要能读回，
// 并且记录随会话删除级联消失。
func TestPostgresRefreshRotation(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	u := auth.User{ID: "u1", PasswordHash: "h"}
	if err := createAccount(ctx, st, u, "rotate@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	sess := auth.Session{
		ID: "s1", UserID: u.ID,
		AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires:  now.Add(time.Hour),
		RefreshExpires: now.Add(24 * time.Hour),
	}
	if err := st.CreateSession(ctx, sess, 20, ""); err != nil {
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

	// 重试路径会更新记录里“本次发出的令牌”，宽限截止时间与 request_id 保持
	// 第一次的值。
	updated := used
	updated.RotatedAt = now.Add(5 * time.Second)
	updated.ReplacedAccessHash, updated.ReplacedRefreshHash = "ah4", "rh4"
	updated.GraceUntil = now.Add(30 * time.Second) // 不应被写入
	if err := st.RecordRefreshUsed(ctx, updated); err != nil {
		t.Fatalf("更新旧令牌记录: %v", err)
	}
	afterUpdate, err := st.UsedRefresh(ctx, "rh1")
	if err != nil {
		t.Fatalf("更新后读取旧令牌记录: %v", err)
	}
	if afterUpdate.ReplacedRefreshHash != "rh4" || afterUpdate.ReplacedAccessHash != "ah4" {
		t.Fatalf("本次发出的令牌应更新，得到 %+v", afterUpdate)
	}
	if !afterUpdate.GraceUntil.Equal(used.GraceUntil) || afterUpdate.RequestID != "req-1" {
		t.Fatalf("宽限截止时间与 request_id 不应被重试改写，得到 %+v", afterUpdate)
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
	u := auth.User{ID: "u1", PasswordHash: "h"}
	if err := createAccount(ctx, st, u, "prune@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now().UTC()
	sess := auth.Session{
		ID: "s1", UserID: u.ID,
		AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires:  now.Add(time.Hour),
		RefreshExpires: now.Add(24 * time.Hour),
	}
	if err := st.CreateSession(ctx, sess, 20, ""); err != nil {
		t.Fatalf("session: %v", err)
	}
	// 把这条会话与两枚验证码分别改成过期与未过期，清理之后只留下未过期的。
	if _, err := st.pool.Exec(ctx, `UPDATE session SET refresh_expires = $1 WHERE id = 's1'`, now.Add(-time.Hour)); err != nil {
		t.Fatalf("expire session: %v", err)
	}
	for _, userID := range []string{u.ID, "u2"} {
		if userID == "u2" {
			if err := createAccount(ctx, st, auth.User{ID: "u2", PasswordHash: "h"}, "keep@b.cn"); err != nil {
				t.Fatalf("second user: %v", err)
			}
		}
		expires := now.Add(-time.Minute)
		if userID == "u2" {
			expires = now.Add(10 * time.Minute)
		}
		if err := st.PutCode(ctx, auth.Code{
			UserID: userID, Purpose: auth.PurposeResetPassword,
			Kind: auth.KindEmail, Identifier: userID + "@b.cn", CodeHash: "hash-" + userID,
			ExpiresAt: expires, CreatedAt: now.Add(-time.Hour),
		}); err != nil {
			t.Fatalf("code %s: %v", userID, err)
		}
	}

	if err := st.PruneExpired(ctx, now, now.Add(-time.Hour)); err != nil {
		t.Fatalf("prune: %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("过期会话应被清理，得到 %v", err)
	}
	if _, err := st.Code(ctx, auth.PurposeResetPassword, auth.KindEmail, u.ID+"@b.cn"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("过期验证码应被清理，得到 %v", err)
	}
	if _, err := st.Code(ctx, auth.PurposeResetPassword, auth.KindEmail, "u2@b.cn"); err != nil {
		t.Fatalf("未过期验证码应保留，得到 %v", err)
	}
}

// TestPostgresDeleteUserAndObjects 检查删号之后对象字节由独立步骤清理。
func TestPostgresDeleteUserAndObjects(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
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
		if err := createAccount(ctx, st, auth.User{ID: id, PasswordHash: "h"}, id+"@b.cn"); err != nil {
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
			Uid: id, DeviceId: "d1", SchemaVersion: 27,
			Actor: "user", Action: "write", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	if r, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1"), mk("r2")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 2 {
		t.Fatalf("append u1: %+v, err %v", r, err)
	}
	if r, err := st.Append(ctx, "u2", 0, []syncsvc.Commit{mk("other")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 1 {
		t.Fatalf("append u2: %+v, err %v", r, err)
	}

	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if state, err := st.State(ctx, "u1"); err != nil || state.Head != 0 {
		t.Fatalf("head after reset = %d, %v", state.Head, err)
	}
	if commits, err := st.After(ctx, "u1", 0, 10, syncsvc.DefaultPullBytes); err != nil || len(commits) != 0 {
		t.Fatalf("commits after reset = %+v, %v", commits, err)
	}
	// 重置之后从 0 重新推送，序号重新从 1 开始。
	if r, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r3")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 1 {
		t.Fatalf("append after reset: %+v, err %v", r, err)
	}
	if state, err := st.State(ctx, "u2"); err != nil || state.Head != 1 {
		t.Fatalf("另一个账号的 head 应保留，得到 %d, %v", state.Head, err)
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
	if err := createAccount(ctx, st, auth.User{ID: userID, PasswordHash: "h"}, email); err != nil {
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
		if err := createAccount(ctx, st, auth.User{ID: id, PasswordHash: "h"}, id+"@b.cn"); err != nil {
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
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
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
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
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
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}

	state, err := st.State(ctx, "u1")
	if err != nil || state.Head != 0 || state.EarliestSeq != 1 || state.Snapshot != nil {
		t.Fatalf("空日志状态应为 head 0、保留下界 1、无快照，得到 %+v %v", state, err)
	}

	mk := func(id string) syncsvc.Commit {
		after := json.RawMessage(`{}`)
		return syncsvc.Commit{
			Uid: id, DeviceId: "d1", SchemaVersion: 26,
			Actor: "user", Action: "写入", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	result, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1"), mk("r2")}, syncsvc.CompactPolicy{})
	if err != nil || result.Head != 2 || len(result.Seqs) != 2 || result.Seqs[0] != 1 || result.Seqs[1] != 2 {
		t.Fatalf("追加两条后 head 应为 2、逐条序号为 1、2，得到 %+v %v", result, err)
	}

	// 完全重放：base 不对也算成功，因为客户端没收到上一次响应；重复的提交回它
	// 原来的序号。
	if result, err = st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1")}, syncsvc.CompactPolicy{}); err != nil || result.Head != 2 || result.Seqs[0] != 1 {
		t.Fatalf("重放应成功并保持 head=2，得到 %+v %v", result, err)
	}
	if result, err = st.Append(ctx, "u1", 1, []syncsvc.Commit{mk("r3")}, syncsvc.CompactPolicy{}); err != syncsvc.ErrHeadMoved || result.Head != 2 {
		t.Fatalf("base 落后应返回 ErrHeadMoved，得到 %+v %v", result, err)
	}

	commits, err := st.After(ctx, "u1", 0, 10, syncsvc.DefaultPullBytes)
	if err != nil || len(commits) != 2 {
		t.Fatalf("拉取应有两条，得到 %d %v", len(commits), err)
	}
	if commits[0].Seq == nil || *commits[0].Seq != 1 || commits[0].Uid != "r1" || len(commits[0].Changes) != 1 {
		t.Fatalf("第一条不符合预期: %+v", commits[0])
	}
	limited, err := st.After(ctx, "u1", 0, 10, 500)
	if err != nil || len(limited) != 1 || limited[0].Uid != "r1" {
		t.Fatalf("按字节分页应保留连续前缀: %+v, %v", limited, err)
	}
}

// TestPostgresSyncSnapshot 守住快照指针、保留期压缩与去重表：登记只保留最新
// 位置，回退与未来位置都被拒绝；保留期之内的登记不删除提交，超过保留期的提交
// 在登记时删除并推进保留下界；压缩删除旧提交之后，重放仍然被去重表跳过；清空
// 云端数据把快照、保留下界与去重身份一起清掉（ADR-0043）。
func TestPostgresSyncSnapshot(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}

	mk := func(id string) syncsvc.Commit {
		after := json.RawMessage(`{}`)
		return syncsvc.Commit{
			Uid: id, DeviceId: "d1", SchemaVersion: 26,
			Actor: "user", Action: "写入", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	snap := syncsvc.Snapshot{
		Seq: 3, SHA256: strings.Repeat("a", 64), Digest: strings.Repeat("b", 64),
	}
	if r, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1"), mk("r2"), mk("r3")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 3 {
		t.Fatalf("追加三条: %+v %v", r, err)
	}
	state, err := st.State(ctx, "u1")
	if err != nil || state.Head != 3 || state.EarliestSeq != 1 || state.Snapshot != nil {
		t.Fatalf("登记之前的状态: %+v %v", state, err)
	}

	// 保留期为零表示不按时间删除，登记之后提交都还在。
	state, err = st.RegisterSnapshot(ctx, "u1", snap, syncsvc.CompactPolicy{})
	if err != nil || state.Snapshot == nil || state.Snapshot.Seq != 3 || state.EarliestSeq != 1 {
		t.Fatalf("登记快照: %+v %v", state, err)
	}
	// 回退覆盖更新的快照被拒绝，状态里带着当前指针。
	older := snap
	older.Seq = 2
	if state, err = st.RegisterSnapshot(ctx, "u1", older, syncsvc.CompactPolicy{}); err != syncsvc.ErrSnapshotStale {
		t.Fatalf("回退登记应返回 ErrSnapshotStale，得到 %+v %v", state, err)
	}
	// 登记 head 之后的位置没有对应提交。
	ahead := snap
	ahead.Seq = 4
	if _, err = st.RegisterSnapshot(ctx, "u1", ahead, syncsvc.CompactPolicy{}); err != syncsvc.ErrInvalid {
		t.Fatalf("未来位置应返回 ErrInvalid，得到 %v", err)
	}
	// 保留窗口之内的提交不删除。
	if state, err = st.RegisterSnapshot(ctx, "u1", snap, syncsvc.CompactPolicy{Keep: time.Hour, AllowDelete: true}); err != nil || state.EarliestSeq != 1 {
		t.Fatalf("保留期之内: %+v %v", state, err)
	}

	// 保留窗口极短：三条提交都早于它，登记时删除，保留下界推进到 4。位置门槛为零
	// 表示活跃窗口内没有设备，压缩不设上限。
	if state, err = st.RegisterSnapshot(ctx, "u1", snap, syncsvc.CompactPolicy{Keep: time.Nanosecond, AllowDelete: true}); err != nil || state.EarliestSeq != 4 || state.Head != 3 {
		t.Fatalf("压缩之后: %+v %v", state, err)
	}
	if commits, err := st.After(ctx, "u1", 0, 10, syncsvc.DefaultPullBytes); err != nil || len(commits) != 0 {
		t.Fatalf("压缩之后不应再拉到提交: %+v %v", commits, err)
	}
	// 去重表保留了接收过的身份：重放旧提交被跳过，head 不变。
	if r, err := st.Append(ctx, "u1", 3, []syncsvc.Commit{mk("r1")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 3 || r.Seqs[0] != 1 {
		t.Fatalf("压缩之后的重放应回原序号: %+v %v", r, err)
	}
	// 新提交照常追加与拉取。
	if r, err := st.Append(ctx, "u1", 3, []syncsvc.Commit{mk("r4")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 4 {
		t.Fatalf("压缩之后的追加: %+v %v", r, err)
	}
	if commits, err := st.After(ctx, "u1", 3, 10, syncsvc.DefaultPullBytes); err != nil || len(commits) != 1 || commits[0].Uid != "r4" {
		t.Fatalf("压缩之后的增量: %+v %v", commits, err)
	}

	// 清空云端数据把快照、保留下界与去重身份一起清掉。
	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if state, err = st.State(ctx, "u1"); err != nil || state.Head != 0 || state.EarliestSeq != 1 || state.Snapshot != nil {
		t.Fatalf("清空之后的状态: %+v %v", state, err)
	}
	// 去重身份也清了：同一编号重新写入从 1 开始。
	if r, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 1 || r.Seqs[0] != 1 {
		t.Fatalf("清空之后重新写入: %+v %v", r, err)
	}
}

// TestPostgresSnapshotOrphansAndDevices 守住待回收表与设备名册的落库：旧指针让位
// 时写入待回收行、宽限期与当前指针两道条件都影响回收；回收先删字节、再删索引
// 行与待回收行；名册按设备标识更新最近出现时间与能力、改名只改已有设备；清空
// 云端数据把两张表一起清掉（ADR-0047、ADR-0048）。
func TestPostgresSnapshotOrphansAndDevices(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	bs := NewBlobStore(st)

	mk := func(id string) syncsvc.Commit {
		after := json.RawMessage(`{}`)
		return syncsvc.Commit{
			Uid: id, DeviceId: "d1", SchemaVersion: 26,
			Actor: "user", Action: "写入", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	if r, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("r1"), mk("r2"), mk("r3")}, syncsvc.CompactPolicy{}); err != nil || r.Head != 3 {
		t.Fatalf("追加三条: %+v %v", r, err)
	}

	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	seed := func(sha string) {
		t.Helper()
		body := []byte("snapshot bytes")
		if err := bs.Save(ctx, "u1", sha, int64(len(body)), bytes.NewReader(body)); err != nil {
			t.Fatalf("写入附件字节: %v", err)
		}
		if _, err := bs.BackfillAttachment(ctx, "u1", sha, int64(len(body))); err != nil {
			t.Fatalf("写入附件索引: %v", err)
		}
	}
	shaC := strings.Repeat("d", 64)
	seed(shaA)
	seed(shaB)

	// 策略不允许删除时只写指针，提交原样保留。
	state, err := st.RegisterSnapshot(ctx, "u1", syncsvc.Snapshot{
		Seq: 1, SHA256: shaA, Digest: strings.Repeat("c", 64),
	}, syncsvc.CompactPolicy{Keep: time.Nanosecond})
	if err != nil || state.EarliestSeq != 1 || state.Snapshot == nil || state.Snapshot.SHA256 != shaA {
		t.Fatalf("不允许删除时登记: %+v %v", state, err)
	}
	if commits, err := st.After(ctx, "u1", 0, 10, syncsvc.DefaultPullBytes); err != nil || len(commits) != 3 {
		t.Fatalf("不允许删除时提交应全部保留: %d %v", len(commits), err)
	}

	// 旧指针让位：A 进入待回收表。
	if _, err := st.RegisterSnapshot(ctx, "u1", syncsvc.Snapshot{
		Seq: 2, SHA256: shaB, Digest: strings.Repeat("c", 64),
	}, syncsvc.CompactPolicy{}); err != nil {
		t.Fatalf("登记 B: %v", err)
	}

	orphans, err := st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(365*24*time.Hour))
	if err != nil || len(orphans) != 1 || orphans[0] != shaA {
		t.Fatalf("A 应在待回收表: %v %v", orphans, err)
	}
	// 宽限期之内不回收。
	if orphans, err = st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(-time.Hour)); err != nil || len(orphans) != 0 {
		t.Fatalf("宽限期之内不该有可回收行: %v %v", orphans, err)
	}
	// 当前指针的哈希即使带着回收标记也排除。
	if _, err := st.pool.Exec(ctx, `UPDATE attachment SET orphaned_at = now() - interval '2 days'
		WHERE user_id = $1 AND sha256 = $2`, "u1", shaB); err != nil {
		t.Fatalf("手动给当前指针写回收标记: %v", err)
	}
	if orphans, err = st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(time.Hour)); err != nil ||
		len(orphans) != 1 || orphans[0] != shaA {
		t.Fatalf("当前指针不应出现在回收列表: %v %v", orphans, err)
	}

	// 回收 A：字节、索引行与待回收行都删掉。
	if err := st.ReclaimOrphan(ctx, "u1", shaA); err != nil {
		t.Fatalf("回收 A: %v", err)
	}
	if _, err := st.objects.Stat(ctx, objectstore.AttachmentKey("u1", shaA)); !errors.Is(err, objectstore.ErrNotFound) {
		t.Fatalf("回收之后字节应删除: %v", err)
	}
	rows, err := bs.ListAttachments(ctx, "u1")
	if err != nil {
		t.Fatalf("列出索引: %v", err)
	}
	for _, row := range rows {
		if row.Sha256 == shaA {
			t.Fatalf("回收之后索引行应删除: %+v", rows)
		}
	}
	if orphans, err = st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(time.Hour)); err != nil ||
		len(orphans) != 0 {
		t.Fatalf("回收之后待回收行应删除: %v %v", orphans, err)
	}

	// 设备名册：带标识的请求更新最近出现时间与能力，补行不动已有能力。
	if err := st.TouchDevice(ctx, "u1", "d1", true, 0); err != nil {
		t.Fatalf("记录 d1: %v", err)
	}
	if err := st.EnsureDevice(ctx, "u1", "d2"); err != nil {
		t.Fatalf("补行 d2: %v", err)
	}
	devices, err := st.Devices(ctx, "u1", 50)
	if err != nil || len(devices) != 2 {
		t.Fatalf("名册: %+v %v", devices, err)
	}
	byID := map[string]syncsvc.Device{}
	for _, device := range devices {
		byID[device.DeviceID] = device
	}
	if got := byID["d1"]; !got.SnapshotCapable {
		t.Fatalf("d1 应记为支持快照: %+v", got)
	}
	if got := byID["d2"]; got.SnapshotCapable || got.Alias != "" || got.SyncedSeq != 0 {
		t.Fatalf("补行设备的别名、快照能力与位置都应为空: %+v", got)
	}
	// 有活跃设备没有声明 snapshot 时门槛应拦下压缩。
	blocked, err := st.ActiveDeviceWithoutSnapshot(ctx, "u1", time.Now().UTC().Add(-time.Hour))
	if err != nil || !blocked {
		t.Fatalf("d2 缺能力时应拦下压缩: %v %v", blocked, err)
	}
	if err := st.TouchDevice(ctx, "u1", "d2", true, 0); err != nil {
		t.Fatalf("更新 d2 能力: %v", err)
	}
	blocked, err = st.ActiveDeviceWithoutSnapshot(ctx, "u1", time.Now().UTC().Add(-time.Hour))
	if err != nil || blocked {
		t.Fatalf("设备都声明能力之后不应拦下压缩: %v %v", blocked, err)
	}
	// 旧版本客户端补行时留下的是 snapshot_capable = false 的设备，它也必须挡住
	// 压缩。
	if err := st.TouchDevice(ctx, "u1", "d3", false, 0); err != nil {
		t.Fatalf("记录不支持快照的设备: %v", err)
	}
	var storedCapable bool
	if err := st.pool.QueryRow(ctx, `SELECT snapshot_capable FROM sync_device WHERE user_id = $1 AND device_id = $2`, "u1", "d3").Scan(&storedCapable); err != nil || storedCapable {
		t.Fatalf("不支持快照的设备在库里应为 false: %v %v", storedCapable, err)
	}
	blocked, err = st.ActiveDeviceWithoutSnapshot(ctx, "u1", time.Now().UTC().Add(-time.Hour))
	if err != nil || !blocked {
		t.Fatalf("不支持快照的设备应拦下压缩: %v %v", blocked, err)
	}
	// 活跃窗口之外没有设备，也不拦。
	blocked, err = st.ActiveDeviceWithoutSnapshot(ctx, "u1", time.Now().UTC().Add(time.Hour))
	if err != nil || blocked {
		t.Fatalf("没有活跃设备时视为可以压缩: %v %v", blocked, err)
	}

	// 改名只改已有设备，未知设备返回 ErrDeviceNotFound。
	renamed, err := st.RenameDevice(ctx, "u1", "d1", "我的手机")
	if err != nil || renamed.Alias != "我的手机" || renamed.DeviceID != "d1" {
		t.Fatalf("改名: %+v %v", renamed, err)
	}
	if _, err := st.RenameDevice(ctx, "u1", "missing", "x"); !errors.Is(err, syncsvc.ErrDeviceNotFound) {
		t.Fatalf("未知设备应返回 ErrDeviceNotFound，得到 %v", err)
	}

	// 清空云端数据把待回收标记与名册一起清掉。这里给一份既不是当前指针、也没被
	// 回收过的附件写上标记，清空之前先确认它确实在可回收列表里，否则清空之后的
	// 空列表说明不了标记被清掉。
	seed(shaC)
	if _, err := st.pool.Exec(ctx, `UPDATE attachment SET orphaned_at = now() WHERE user_id = $1 AND sha256 = $2`, "u1", shaC); err != nil {
		t.Fatalf("写回收标记: %v", err)
	}
	if orphans, err = st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(time.Hour)); err != nil ||
		len(orphans) != 1 || orphans[0] != shaC {
		t.Fatalf("清空之前应有一行可回收: %v %v", orphans, err)
	}
	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if orphans, err = st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(24*time.Hour)); err != nil || len(orphans) != 0 {
		t.Fatalf("清空之后待回收表应为空: %v %v", orphans, err)
	}
	if devices, err = st.Devices(ctx, "u1", 50); err != nil || len(devices) != 0 {
		t.Fatalf("清空之后名册应为空: %+v %v", devices, err)
	}
}

func TestPostgresBackupsAndQuota(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "a@b.cn"); err != nil {
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

	chat, emb := llmproxy.KindChat, llmproxy.KindEmbedding
	if used, err := st.Used(ctx, "u1", "2026-11-15", chat); err != nil || used != 0 {
		t.Fatalf("未用过的日子应为 0，得到 %d %v", used, err)
	}
	if err := st.Add(ctx, "u1", "2026-11-15", chat, 120); err != nil {
		t.Fatalf("add: %v", err)
	}
	if err := st.Add(ctx, "u1", "2026-11-15", chat, 30); err != nil {
		t.Fatalf("add again: %v", err)
	}
	if err := st.Add(ctx, "u1", "2026-11-15", emb, 9000); err != nil {
		t.Fatalf("add embedding: %v", err)
	}
	if used, err := st.Used(ctx, "u1", "2026-11-15", chat); err != nil || used != 150 {
		t.Fatalf("聊天用量应累加到 150，得到 %d %v", used, err)
	}
	if used, err := st.Used(ctx, "u1", "2026-11-15", emb); err != nil || used != 9000 {
		t.Fatalf("嵌入用量应单独计，得到 %d %v", used, err)
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
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "active@b.cn"); err != nil {
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
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "quota@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	if _, ok, err := st.DailyLimit(ctx, "u1", llmproxy.KindChat); err != nil || ok {
		t.Fatalf("没有覆盖行时应回落到默认值：ok=%v err=%v", ok, err)
	}

	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_quota (user_id, daily_tokens, note) VALUES ('u1', 5000, '内测')`); err != nil {
		t.Fatalf("insert override: %v", err)
	}
	limit, ok, err := st.DailyLimit(ctx, "u1", llmproxy.KindChat)
	if err != nil || !ok || limit != 5000 {
		t.Fatalf("覆盖额度没有读到：limit=%d ok=%v err=%v", limit, ok, err)
	}
	// 嵌入那一列为空：回落到嵌入的默认值。
	if _, ok, err := st.DailyLimit(ctx, "u1", llmproxy.KindEmbedding); err != nil || ok {
		t.Fatalf("嵌入列为空时应回落到默认值：ok=%v err=%v", ok, err)
	}
	if _, err := st.pool.Exec(ctx, `UPDATE llm_quota SET embedding_daily_tokens = 900000 WHERE user_id = 'u1'`); err != nil {
		t.Fatalf("update override: %v", err)
	}
	if limit, ok, err := st.DailyLimit(ctx, "u1", llmproxy.KindEmbedding); err != nil || !ok || limit != 900000 {
		t.Fatalf("嵌入覆盖额度没有读到：limit=%d ok=%v err=%v", limit, ok, err)
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

// TestPostgresCatalog 核对模型来源与路由的读写：路由整体替换并保持顺序，
// 指向不存在的来源时报 ErrUnknownProvider，来源被路由引用时不能删除，删除
// 模型时路由随外键级联删除。
func TestPostgresCatalog(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)

	if _, err := st.Provider(ctx, "sf"); !errors.Is(err, llmproxy.ErrNotFound) {
		t.Fatalf("不存在的来源应返回 ErrNotFound，得到 %v", err)
	}
	p := llmproxy.ProviderRecord{ID: "sf", Name: "硅基流动", BaseURL: "https://api.siliconflow.cn/v1", APIKeySealed: "v1:xxx", KeyHint: "abcd", Enabled: true, Note: "嵌入", UpdatedAt: now}
	if err := st.PutProvider(ctx, p); err != nil {
		t.Fatalf("put provider: %v", err)
	}
	p.Name = "SiliconFlow"
	if err := st.PutProvider(ctx, p); err != nil {
		t.Fatalf("update provider: %v", err)
	}
	got, err := st.Provider(ctx, "sf")
	if err != nil || got.Name != "SiliconFlow" || got.APIKeySealed != "v1:xxx" || got.KeyHint != "abcd" || !got.UpdatedAt.Equal(now) {
		t.Fatalf("provider round trip: %+v %v", got, err)
	}
	if err := st.PutProvider(ctx, llmproxy.ProviderRecord{ID: "ds", BaseURL: "https://api.deepseek.com/v1", Enabled: true, UpdatedAt: now}); err != nil {
		t.Fatalf("put second provider: %v", err)
	}

	m := llmproxy.ModelRecord{Name: "zhixin-embed", Kind: llmproxy.KindEmbedding, Enabled: true, Dimensions: 1024, UpdatedAt: now, Routes: []llmproxy.Route{
		{ProviderID: "sf", UpstreamModel: "BAAI/bge-m3", Priority: 0, Weight: 3, MaxBatch: 32, Enabled: true},
		{ProviderID: "ds", UpstreamModel: "bge-m3", Priority: 1, Weight: 1, Enabled: false},
	}}
	if err := st.PutModel(ctx, m); err != nil {
		t.Fatalf("put model: %v", err)
	}
	bad := m
	bad.Routes = []llmproxy.Route{{ProviderID: "missing", UpstreamModel: "x", Weight: 1}}
	if err := st.PutModel(ctx, bad); !errors.Is(err, llmproxy.ErrUnknownProvider) {
		t.Fatalf("指向不存在的来源应报 ErrUnknownProvider，得到 %v", err)
	}
	models, err := st.Models(ctx)
	if err != nil || len(models) != 1 {
		t.Fatalf("models: %v %+v", err, models)
	}
	got2 := models[0]
	if got2.Dimensions != 1024 || len(got2.Routes) != 2 || got2.Routes[0].ProviderID != "sf" || got2.Routes[0].MaxBatch != 32 || got2.Routes[1].Enabled {
		t.Fatalf("事务失败后应保留原来的路由并按顺序读回：%+v", got2)
	}

	if err := st.DeleteProvider(ctx, "sf"); !errors.Is(err, llmproxy.ErrProviderInUse) {
		t.Fatalf("被路由引用的来源不能删除，得到 %v", err)
	}
	m.Routes = m.Routes[1:]
	if err := st.PutModel(ctx, m); err != nil {
		t.Fatalf("replace routes: %v", err)
	}
	if err := st.DeleteProvider(ctx, "sf"); err != nil {
		t.Fatalf("没有路由引用之后可以删除：%v", err)
	}
	if err := st.DeleteProvider(ctx, "sf"); !errors.Is(err, llmproxy.ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound，得到 %v", err)
	}
	if err := st.DeleteModel(ctx, "zhixin-embed"); err != nil {
		t.Fatalf("delete model: %v", err)
	}
	var routes int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM llm_route`).Scan(&routes); err != nil || routes != 0 {
		t.Fatalf("删除模型后路由应级联删除：%d %v", routes, err)
	}
	if err := st.DeleteModel(ctx, "zhixin-embed"); !errors.Is(err, llmproxy.ErrNotFound) {
		t.Fatalf("重复删除应返回 ErrNotFound，得到 %v", err)
	}
}
