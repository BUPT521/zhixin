package auth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// TestRotateSessionAndRecordIsAtomic 核对存储层的轮换与重放记录一起生效：CAS
// 成功时两者都可读，CAS 失败时既不改会话也不写记录。
func TestRotateSessionAndRecordIsAtomic(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	st := NewMemoryStore()
	createEmailAccount(t, st, User{ID: "u1", PasswordHash: "h", CreatedAt: now}, "atomic@b.cn")
	if err := st.CreateSession(ctx, Session{
		ID: "s1", UserID: "u1", AccessHash: "ah1", RefreshHash: "rh1",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(24 * time.Hour), CreatedAt: now,
	}, 20, ""); err != nil {
		t.Fatal(err)
	}

	used := RefreshUsed{
		TokenHash: "rh1", SessionID: "s1", UserID: "u1", RequestID: "req-1",
		RotatedAt: now, GraceUntil: now.Add(time.Minute),
	}
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh1", "ah2", "rh2",
		now.Add(2*time.Hour), now.Add(48*time.Hour), used); err != nil {
		t.Fatalf("第一次原子轮换: %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah2"); err != nil {
		t.Fatalf("轮换后的访问摘要应能查到: %v", err)
	}
	record, err := st.UsedRefresh(ctx, "rh1")
	if err != nil {
		t.Fatalf("重放记录应与轮换一起写入: %v", err)
	}
	if record.RequestID != "req-1" || record.ReplacedRefreshHash != "rh2" {
		t.Fatalf("重放记录不符合预期: %+v", record)
	}

	// 用同一个旧摘要再轮换（并发输家）：返回 ErrInvalidToken，会话与记录都不动。
	loser := used
	loser.RequestID = "req-2"
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh1", "ah3", "rh3",
		now.Add(3*time.Hour), now.Add(72*time.Hour), loser); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("旧摘要再轮换应返回 ErrInvalidToken，得到 %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah2"); err != nil {
		t.Fatalf("失败的轮换不应改会话: %v", err)
	}
	record, err = st.UsedRefresh(ctx, "rh1")
	if err != nil || record.RequestID != "req-1" {
		t.Fatalf("失败的轮换不应改重放记录：%+v %v", record, err)
	}
}

// TestRotateSessionAndRecordRetryWritesBothHashes 核对宽限期内的重试：客户端提交
// 的更早摘要与这次消费的当前摘要不同，两条记录都指向本次发出的新令牌，宽限
// 截止时间沿用第一次的值。
func TestRotateSessionAndRecordRetryWritesBothHashes(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	st := NewMemoryStore()
	createEmailAccount(t, st, User{ID: "u1", PasswordHash: "h", CreatedAt: now}, "retry@b.cn")
	if err := st.CreateSession(ctx, Session{
		ID: "s1", UserID: "u1", AccessHash: "ah2", RefreshHash: "rh2",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(24 * time.Hour), CreatedAt: now,
	}, 20, ""); err != nil {
		t.Fatal(err)
	}
	firstGrace := now.Add(time.Minute)
	used := RefreshUsed{
		TokenHash: "rh1", SessionID: "s1", UserID: "u1", RequestID: "req-1",
		RotatedAt: now, GraceUntil: firstGrace,
	}
	if err := st.RotateSessionAndRecord(ctx, "s1", "rh2", "ah3", "rh3",
		now.Add(2*time.Hour), now.Add(48*time.Hour), used); err != nil {
		t.Fatalf("重试轮换: %v", err)
	}
	for _, hash := range []string{"rh1", "rh2"} {
		record, err := st.UsedRefresh(ctx, hash)
		if err != nil {
			t.Fatalf("%s 的重放记录应写入: %v", hash, err)
		}
		if record.ReplacedRefreshHash != "rh3" || record.RequestID != "req-1" || !record.GraceUntil.Equal(firstGrace) {
			t.Fatalf("%s 的记录不符合预期: %+v", hash, record)
		}
	}
}

// TestHandlerRegisterGlobalBudget 核对注册的实例级上限：按来源地址的桶放行之后，
// 全局桶用尽时在解码请求体与哈希之前返回 429，被挡下的注册不会写账号。
func TestHandlerRegisterGlobalBudget(t *testing.T) {
	svc := NewService(NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := NewHandler(svc, log, testMaxJSON, nil, nil, nil, httpx.RemoteHost)
	// 全局桶只有一个名额、不补充：第二次注册一定会被挡住。
	h.SetRegisterGlobalLimiter(ratelimit.New(rate.Limit(0), 1, 0))
	c := testutil.NewClient(t, testutil.NewServer(
		testAPI{h: h},
		httpx.RequestID,
		Middleware(svc, log),
	))

	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"identifier": "first@b.cn", "password": "password1",
	}, nil); code != http.StatusCreated {
		t.Fatalf("第一次注册应成功，得到 %d", code)
	}
	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"identifier": "second@b.cn", "password": "password1",
	}, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("全局桶用尽后应回 429：%d %+v", code, p)
	}
	if _, err := svc.store.UserByIdentifier(context.Background(), KindEmail, "second@b.cn"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("被挡下的注册不应写账号，得到 %v", err)
	}
}

// TestMemoryPruneUnverified 核对内存实现只删“创建早于截止时间且没有任何一种
// 已验证登录方式”的账号，账号的会话、验证码与重放记录一起消失；已确认的账号与
// 保留期内的账号不受影响。
func TestMemoryPruneUnverified(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)
	st := NewMemoryStore()
	createEmailAccount(t, st, User{ID: "old-unverified", PasswordHash: "h", CreatedAt: now.Add(-8 * 24 * time.Hour)}, "old@b.cn")
	createEmailAccount(t, st, User{ID: "recent-unverified", PasswordHash: "h", CreatedAt: now.Add(-6 * 24 * time.Hour)}, "recent@b.cn")
	verifiedIdentity := createEmailAccount(t, st, User{ID: "old-verified", PasswordHash: "h", CreatedAt: now.Add(-30 * 24 * time.Hour)}, "verified@b.cn")
	if err := st.SetIdentityVerified(ctx, "old-verified", verifiedIdentity.ID, now.Add(-7*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateSession(ctx, Session{
		ID: "s-old", UserID: "old-unverified", AccessHash: "ah", RefreshHash: "rh",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(24 * time.Hour), CreatedAt: now,
	}, 20, ""); err != nil {
		t.Fatal(err)
	}
	if err := st.PutCode(ctx, Code{
		UserID: "old-unverified", Purpose: PurposeVerifyContact,
		Kind: KindEmail, Identifier: "old@b.cn", CodeHash: "c",
		ExpiresAt: now.Add(time.Minute), CreatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.RotateSessionAndRecord(ctx, "s-old", "rh", "ah", "rh2",
		now.Add(2*time.Hour), now.Add(48*time.Hour), RefreshUsed{
			TokenHash: "rh0", SessionID: "s-old", UserID: "old-unverified",
			RequestID: "req", RotatedAt: now, GraceUntil: now.Add(time.Minute),
		}); err != nil {
		t.Fatal(err)
	}

	removed, err := st.PruneUnverified(ctx, now.Add(-7*24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if removed != 1 {
		t.Fatalf("应只删一个未确认且过期的账号，得到 %d", removed)
	}
	if _, err := st.UserByID(ctx, "old-unverified"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("过期的未确认账号应被删除，得到 %v", err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("账号的会话应一并删除，得到 %v", err)
	}
	if _, err := st.Code(ctx, PurposeVerifyContact, KindEmail, "old@b.cn"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("账号的验证码应一并删除，得到 %v", err)
	}
	if _, err := st.UsedRefresh(ctx, "rh0"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("账号的重放记录应一并删除，得到 %v", err)
	}
	for _, id := range []string{"recent-unverified", "old-verified"} {
		if _, err := st.UserByID(ctx, id); err != nil {
			t.Fatalf("%s 应保留: %v", id, err)
		}
	}
}

// TestPruneLoopDeletesUnverifiedUsers 核对每日清理按保留期删除未验证账号：启动
// 清理时按 now-days 算截止时间，超过保留期未确认的账号被删，保留期内的与已确认
// 的账号保留；保留天数默认 7 天，SetUnverifiedKeep 可以覆盖。
func TestPruneLoopDeletesUnverifiedUsers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s, c := newTestService()
	s.SetUnverifiedKeep(1)
	st := s.store.(*MemoryStore)
	createEmailAccount(t, st, User{ID: "expired", PasswordHash: "h", CreatedAt: c.t.Add(-48 * time.Hour)}, "expired@b.cn")
	createEmailAccount(t, st, User{ID: "fresh", PasswordHash: "h", CreatedAt: c.t.Add(-12 * time.Hour)}, "fresh@b.cn")
	verifiedIdentity := createEmailAccount(t, st, User{ID: "verified", PasswordHash: "h", CreatedAt: c.t.Add(-48 * time.Hour)}, "verified@b.cn")
	if err := st.SetIdentityVerified(ctx, "verified", verifiedIdentity.ID, c.t.Add(-49*time.Hour)); err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})
	go func() {
		s.PruneLoop(ctx, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
		close(done)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := st.UserByID(ctx, "expired"); errors.Is(err, ErrNotFound) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("ctx 结束之后 PruneLoop 应当退出")
	}

	if _, err := st.UserByID(ctx, "expired"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("超过保留期的未确认账号应被清理，得到 %v", err)
	}
	for _, id := range []string{"fresh", "verified"} {
		if _, err := st.UserByID(ctx, id); err != nil {
			t.Fatalf("%s 应保留: %v", id, err)
		}
	}
	if got := NewService(NewMemoryStore(), time.Hour, 24*time.Hour).unverifiedKeep; got != 7*24*time.Hour {
		t.Fatalf("默认保留期应为 7 天，得到 %v", got)
	}
}
