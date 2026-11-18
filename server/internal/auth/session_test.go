package auth

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

// sessionCount 读内存存储里的会话数；调用处都没有并发写，不额外加锁。
func sessionCount(s *Service) int {
	return len(s.store.(*MemoryStore).sessions)
}

// TestSessionLimitDropsOldest 核对登录超过上限时删掉最旧的一台：注册的那台
// 最早，第 4 次建会话之后它的令牌应当失效。
func TestSessionLimitDropsOldest(t *testing.T) {
	ctx := context.Background()
	s, c := newTestService()
	s.SetMaxSessions(3)
	first, err := s.Register(ctx, "a@b.cn", "password1", "first")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		c.t = c.t.Add(time.Second)
		if _, err := s.Login(ctx, "a@b.cn", "password1", fmt.Sprintf("phone-%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if got := sessionCount(s); got != 3 {
		t.Fatalf("上限 3 时应保留 3 条会话，得到 %d", got)
	}
	if _, err := s.Authenticate(ctx, first.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("最旧的一台应当被踢掉，得到 %v", err)
	}
}

// TestDefaultSessionLimit 核对默认上限 20：注册一台再登录 20 台，共 21 次建
// 会话之后只剩最新的 20 条，注册那一台被删掉。
func TestDefaultSessionLimit(t *testing.T) {
	ctx := context.Background()
	s, c := newTestService()
	first, err := s.Register(ctx, "a@b.cn", "password1", "first")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		c.t = c.t.Add(time.Second)
		if _, err := s.Login(ctx, "a@b.cn", "password1", fmt.Sprintf("phone-%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if got := sessionCount(s); got != 20 {
		t.Fatalf("默认上限应保留 20 条会话，得到 %d", got)
	}
	if _, err := s.Authenticate(ctx, first.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("最早的一台应当被踢掉，得到 %v", err)
	}
}

// TestSessionLimitHoldsUnderConcurrentLogin 核对并发登录也不会超过上限：
// 上限在存储的锁里执行，不是先数后插。
func TestSessionLimitHoldsUnderConcurrentLogin(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	s.SetMaxSessions(2)
	if _, err := s.Register(ctx, "a@b.cn", "password1", ""); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Login(ctx, "a@b.cn", "password1", ""); err != nil {
				t.Errorf("并发登录失败: %v", err)
			}
		}()
	}
	wg.Wait()
	if got := sessionCount(s); got > 2 {
		t.Fatalf("并发登录后会话数应不超过上限 2，得到 %d", got)
	}
}

// TestPruneExpiredRows 核对过期会话与过期验证码会被清掉，没过期的不动。
func TestPruneExpiredRows(t *testing.T) {
	ctx := context.Background()
	s, c := newTestService()
	st := s.store.(*MemoryStore)
	now := c.t
	expired := Session{
		ID: "old", UserID: "u1", RefreshHash: "old-refresh",
		AccessExpires: now.Add(-time.Minute), RefreshExpires: now.Add(-time.Minute),
		CreatedAt: now.Add(-2 * time.Hour),
	}
	live := Session{
		ID: "new", UserID: "u1", RefreshHash: "new-refresh",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(24 * time.Hour),
		CreatedAt: now,
	}
	for _, sess := range []Session{expired, live} {
		if err := st.CreateSession(ctx, sess, 20); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.PutCode(ctx, Code{UserID: "u1", Purpose: PurposeResetPassword, CodeHash: "old", ExpiresAt: now.Add(-time.Minute), CreatedAt: now.Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutCode(ctx, Code{UserID: "u1", Purpose: PurposeVerifyEmail, CodeHash: "live", ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now}); err != nil {
		t.Fatal(err)
	}

	if err := st.PruneExpired(ctx, now); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "old-refresh"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("过期会话应被清理，得到 %v", err)
	}
	if _, err := st.SessionByRefreshHash(ctx, "new-refresh"); err != nil {
		t.Fatalf("未过期会话应保留，得到 %v", err)
	}
	if _, err := st.Code(ctx, "u1", PurposeResetPassword); !errors.Is(err, ErrNotFound) {
		t.Fatalf("过期验证码应被清理，得到 %v", err)
	}
	if _, err := st.Code(ctx, "u1", PurposeVerifyEmail); err != nil {
		t.Fatalf("未过期验证码应保留，得到 %v", err)
	}
}

// TestPruneLoopCleansAtStartup 核对每日清理在启动时先跑一次，ctx 结束之后退出。
func TestPruneLoopCleansAtStartup(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s, c := newTestService()
	st := s.store.(*MemoryStore)
	if err := st.CreateSession(ctx, Session{
		ID: "old", UserID: "u1", RefreshHash: "old-refresh",
		AccessExpires: c.t.Add(-time.Minute), RefreshExpires: c.t.Add(-time.Minute),
		CreatedAt: c.t.Add(-2 * time.Hour),
	}, 20); err != nil {
		t.Fatal(err)
	}

	done := make(chan struct{})
	go func() {
		s.PruneLoop(ctx, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
		close(done)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := st.SessionByRefreshHash(ctx, "old-refresh"); errors.Is(err, ErrNotFound) {
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
	if _, err := st.SessionByRefreshHash(ctx, "old-refresh"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("启动清理应当删掉过期会话，得到 %v", err)
	}
}
