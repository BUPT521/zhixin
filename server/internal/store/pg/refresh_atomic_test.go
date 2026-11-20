package pg

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
)

// TestPostgresRotateSessionAndRecordIsAtomic 核对 PostgreSQL 的原子轮换：轮换与
// 重放记录在同一个事务里提交；记录写不进去时轮换一并回滚，旧刷新摘要仍然可用。
func TestPostgresRotateSessionAndRecordIsAtomic(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)

	u := auth.User{ID: "u1", Email: "atomic@b.cn", PasswordHash: "h"}
	if err := st.CreateUser(ctx, u); err != nil {
		t.Fatalf("user: %v", err)
	}
	sess := auth.Session{
		ID: "s1", UserID: u.ID, AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(24 * time.Hour),
	}
	if err := st.CreateSession(ctx, sess, 20, ""); err != nil {
		t.Fatalf("session: %v", err)
	}

	used := auth.RefreshUsed{
		TokenHash: "rh1", SessionID: "s1", UserID: u.ID, RequestID: "req-1",
		RotatedAt: now, GraceUntil: now.Add(time.Minute),
		ReplacedAccessHash: "ah2", ReplacedRefreshHash: "rh2",
	}
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh1", "ah2", "rh2",
		now.Add(2*time.Hour), now.Add(48*time.Hour), used); err != nil {
		t.Fatalf("原子轮换: %v", err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "rh2"); err != nil {
		t.Fatalf("轮换后的刷新摘要应能查到: %v", err)
	}
	got, err := st.UsedRefresh(ctx, "rh1")
	if err != nil || got.RequestID != "req-1" || got.ReplacedRefreshHash != "rh2" {
		t.Fatalf("重放记录应与轮换一起写入：%+v %v", got, err)
	}

	// 宽限期内的重试：客户端提交的 rh1 与当前会话 rh2 不同，存储把两条记录
	// 一起写进同一个事务，都指向这次发出的 rh5。
	retry := auth.RefreshUsed{
		TokenHash: "rh1", SessionID: "s1", UserID: u.ID, RequestID: "req-1",
		RotatedAt: now, GraceUntil: now.Add(time.Minute),
		ReplacedAccessHash: "ah5", ReplacedRefreshHash: "rh5",
	}
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh2", "ah5", "rh5",
		now.Add(3*time.Hour), now.Add(72*time.Hour), retry); err != nil {
		t.Fatalf("重试轮换: %v", err)
	}
	for _, hash := range []string{"rh1", "rh2"} {
		record, err := st.UsedRefresh(ctx, hash)
		if err != nil || record.ReplacedRefreshHash != "rh5" {
			t.Fatalf("%s 的记录应指向新令牌：%+v %v", hash, record, err)
		}
	}

	// 记录写不进去（会话外键指向不存在的会话）时整个事务回滚：会话仍是 rh5，
	// 新令牌 rh6 不存在，也不留下这条记录。
	bad := auth.RefreshUsed{
		TokenHash: "rh5", SessionID: "missing-session", UserID: u.ID, RequestID: "req-2",
		RotatedAt: now, GraceUntil: now.Add(time.Minute),
		ReplacedAccessHash: "ah6", ReplacedRefreshHash: "rh6",
	}
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh5", "ah6", "rh6",
		now.Add(4*time.Hour), now.Add(96*time.Hour), bad); err == nil {
		t.Fatal("记录写入失败时轮换应一并失败")
	}
	if _, err := st.SessionByRefreshHash(ctx, "rh5"); err != nil {
		t.Fatalf("记录写入失败之后会话应保持原样: %v", err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "rh6"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("回滚之后新刷新摘要不应存在，得到 %v", err)
	}
	if _, err := st.UsedRefresh(ctx, "rh5"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("回滚之后不应留下重放记录，得到 %v", err)
	}

	// CAS 失败返回 ErrInvalidToken，且不写记录。
	stale := auth.RefreshUsed{
		TokenHash: "rh-old", SessionID: "s1", UserID: u.ID, RequestID: "req-3",
		RotatedAt: now, GraceUntil: now.Add(time.Minute),
		ReplacedAccessHash: "ah7", ReplacedRefreshHash: "rh7",
	}
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh-old", "ah7", "rh7",
		now.Add(5*time.Hour), now.Add(120*time.Hour), stale); !errors.Is(err, auth.ErrInvalidToken) {
		t.Fatalf("旧摘要轮换应返回 ErrInvalidToken，得到 %v", err)
	}
	if _, err := st.UsedRefresh(ctx, "rh-old"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("CAS 失败时不应写重放记录，得到 %v", err)
	}
}

// TestPostgresPruneUnverified 核对 PostgreSQL 的未验证账号保留期：只删创建时间
// 早于截止时间且从未确认邮箱的账号，账号的会话与验证码随外键级联删除；保留期
// 内的与已确认的账号不受影响。
func TestPostgresPruneUnverified(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)

	for _, u := range []auth.User{
		{ID: "expired", Email: "expired@b.cn", PasswordHash: "h"},
		{ID: "fresh", Email: "fresh@b.cn", PasswordHash: "h"},
		{ID: "verified", Email: "verified@b.cn", PasswordHash: "h"},
	} {
		if err := st.CreateUser(ctx, u); err != nil {
			t.Fatalf("user %s: %v", u.ID, err)
		}
	}
	// created_at 由数据库默认值写入，用例直接改成需要的时间。
	for id, created := range map[string]time.Time{
		"expired":  now.Add(-8 * 24 * time.Hour),
		"fresh":    now.Add(-6 * 24 * time.Hour),
		"verified": now.Add(-8 * 24 * time.Hour),
	} {
		if _, err := st.pool.Exec(ctx, "UPDATE app_user SET created_at = $1 WHERE id = $2", created, id); err != nil {
			t.Fatalf("改 created_at %s: %v", id, err)
		}
	}
	if _, err := st.pool.Exec(ctx, "UPDATE app_user SET email_verified_at = $1 WHERE id = 'verified'", now); err != nil {
		t.Fatalf("标记已验证: %v", err)
	}
	if err := st.CreateSession(ctx, auth.Session{
		ID: "s-expired", UserID: "expired", AccessHash: "ah-expired", RefreshHash: "rh-expired",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(24 * time.Hour),
	}, 20, ""); err != nil {
		t.Fatalf("session: %v", err)
	}
	if err := st.PutCode(ctx, auth.Code{
		UserID: "expired", Purpose: auth.PurposeVerifyEmail, CodeHash: "c",
		ExpiresAt: now.Add(time.Minute), CreatedAt: now,
	}); err != nil {
		t.Fatalf("code: %v", err)
	}

	removed, err := st.PruneUnverified(ctx, now.Add(-7*24*time.Hour))
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 1 {
		t.Fatalf("应只删一个未验证且过期的账号，得到 %d", removed)
	}
	if _, err := st.UserByID(ctx, "expired"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("过期未验证账号应被删除，得到 %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah-expired"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("账号的会话应随外键级联删除，得到 %v", err)
	}
	if _, err := st.Code(ctx, "expired", auth.PurposeVerifyEmail); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("账号的验证码应随外键级联删除，得到 %v", err)
	}
	for _, id := range []string{"fresh", "verified"} {
		if _, err := st.UserByID(ctx, id); err != nil {
			t.Fatalf("%s 应保留: %v", id, err)
		}
	}
}
