package auth

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// syncBuffer 让并发用例也能从安全日志里读断言结果。
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.String()
}

// newRefreshService 返回带安全日志缓冲的服务，用例从缓冲里核对安全事件。
func newRefreshService(t *testing.T) (*Service, *clock, *syncBuffer) {
	t.Helper()
	s, c := newTestService()
	buf := &syncBuffer{}
	s.SetSecurityLog(slog.New(slog.NewTextHandler(buf, nil)))
	return s, c, buf
}

// TestRefreshKeepsSessionAndRotates 核对轮换保留会话 id、换掉两个令牌摘要：
// 旧访问令牌随轮换失效，新的一对可用。
func TestRefreshKeepsSessionAndRotates(t *testing.T) {
	ctx := context.Background()
	s, c, _ := newRefreshService(t)
	first, err := s.Register(ctx, "a@b.cn", "password1", "phone")
	if err != nil {
		t.Fatal(err)
	}
	st := s.store.(*MemoryStore)
	before, err := st.SessionByAccessHash(ctx, hashToken(first.AccessToken))
	if err != nil {
		t.Fatal(err)
	}

	c.t = c.t.Add(2 * time.Hour)
	second, err := s.Refresh(ctx, first.RefreshToken, "req-1")
	if err != nil {
		t.Fatal(err)
	}
	after, err := st.SessionByAccessHash(ctx, hashToken(second.AccessToken))
	if err != nil {
		t.Fatal(err)
	}
	if after.ID != before.ID {
		t.Fatalf("轮换应保留会话 id：%s → %s", before.ID, after.ID)
	}
	if _, err := s.Authenticate(ctx, first.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("轮换之后旧访问令牌应失效，得到 %v", err)
	}
	if _, err := s.Authenticate(ctx, second.AccessToken); err != nil {
		t.Fatalf("新访问令牌应可用: %v", err)
	}
}

// TestRefreshRetryWithinGrace 核对宽限期内带同一 request_id 的重试成功，连续
// 重试也能拿到可用令牌，且不记安全事件。
func TestRefreshRetryWithinGrace(t *testing.T) {
	ctx := context.Background()
	s, c, buf := newRefreshService(t)
	first, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(2 * time.Hour)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-1"); err != nil {
		t.Fatal(err)
	}

	for i := 0; i < 3; i++ {
		c.t = c.t.Add(5 * time.Second)
		retry, err := s.Refresh(ctx, first.RefreshToken, "req-1")
		if err != nil {
			t.Fatalf("第 %d 次重试应当成功: %v", i+1, err)
		}
		if _, err := s.Authenticate(ctx, retry.AccessToken); err != nil {
			t.Fatalf("第 %d 次重试返回的访问令牌应可用: %v", i+1, err)
		}
		if i == 2 {
			if _, err := s.Refresh(ctx, retry.RefreshToken, "req-1"); err != nil {
				t.Fatalf("重试返回的刷新令牌应可用: %v", err)
			}
		}
	}
	if strings.Contains(buf.String(), "refresh token reuse") {
		t.Fatalf("重试不应记安全事件: %s", buf.String())
	}
}

// TestRefreshReplayWithoutRequestIDRevokes 核对没有 request_id 的重放撤销该账号
// 全部会话，并留下一条安全事件。
func TestRefreshReplayWithoutRequestIDRevokes(t *testing.T) {
	ctx := context.Background()
	s, c, buf := newRefreshService(t)
	first, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(2 * time.Hour)
	second, err := s.Refresh(ctx, first.RefreshToken, "req-1")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := s.Refresh(ctx, first.RefreshToken, ""); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("无 request_id 的重放应返回无效令牌，得到 %v", err)
	}
	if _, err := s.Authenticate(ctx, second.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("重放之后该账号的会话应全部撤销")
	}
	if got := sessionCount(s); got != 0 {
		t.Fatalf("重放之后应没有会话，得到 %d", got)
	}
	if got := buf.String(); !strings.Contains(got, "refresh token reuse") || !strings.Contains(got, "user_id") {
		t.Fatalf("应记一条含账号字段的安全事件，得到 %q", got)
	}
}

// TestRefreshReplayAfterGraceRevokes 核对宽限期过后的重放同样撤销会话。
func TestRefreshReplayAfterGraceRevokes(t *testing.T) {
	ctx := context.Background()
	s, c, _ := newRefreshService(t)
	first, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(2 * time.Hour)
	second, err := s.Refresh(ctx, first.RefreshToken, "req-1")
	if err != nil {
		t.Fatal(err)
	}

	c.t = c.t.Add(refreshGrace + time.Second)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-1"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("宽限期过后的重放应返回无效令牌，得到 %v", err)
	}
	if _, err := s.Authenticate(ctx, second.AccessToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatal("宽限期过后的重放应撤销会话")
	}
}

// TestRefreshReplayDifferentRequestIDRevokes 核对 request_id 与原记录不同时
// 按盗用处理，即使仍在宽限期内。
func TestRefreshReplayDifferentRequestIDRevokes(t *testing.T) {
	ctx := context.Background()
	s, c, _ := newRefreshService(t)
	first, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(2 * time.Hour)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-2"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("request_id 不同的重放应返回无效令牌，得到 %v", err)
	}
	if got := sessionCount(s); got != 0 {
		t.Fatalf("按盗用处理之后应没有会话，得到 %d", got)
	}
}

// TestRefreshRetryDoesNotExtendGrace 守住“重试不顺延宽限”：第一次轮换 61 秒
// 之后，同一个旧令牌即使带同一 request_id 也不再按重试处理。
func TestRefreshRetryDoesNotExtendGrace(t *testing.T) {
	ctx := context.Background()
	s, c, _ := newRefreshService(t)
	first, _ := s.Register(ctx, "a@b.cn", "password1", "")
	c.t = c.t.Add(2 * time.Hour)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-1"); err != nil {
		t.Fatal(err)
	}
	c.t = c.t.Add(30 * time.Second)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-1"); err != nil {
		t.Fatalf("宽限期内的重试应当成功: %v", err)
	}
	c.t = c.t.Add(refreshGrace - 29*time.Second)
	if _, err := s.Refresh(ctx, first.RefreshToken, "req-1"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("重试不应延长宽限期，得到 %v", err)
	}
}

// TestConcurrentRefreshOneWins 核对并发刷新同一个令牌只有一个成功：CAS 的输家
// 返回 ErrInvalidToken；如果输家的 request_id 不同，还会按重放撤销会话，所以只
// 断言一成一败，不断言会话仍然存在。
func TestConcurrentRefreshOneWins(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	reg, err := s.Register(ctx, "a@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := s.Refresh(ctx, reg.RefreshToken, fmt.Sprintf("req-%d", i))
			results <- err
		}(i)
	}
	wg.Wait()
	close(results)
	success, rejected := 0, 0
	for err := range results {
		switch {
		case err == nil:
			success++
		case errors.Is(err, ErrInvalidToken):
			rejected++
		default:
			t.Fatalf("并发刷新返回了意外的错误: %v", err)
		}
	}
	if success != 1 || rejected != 1 {
		t.Fatalf("并发刷新应只有一个成功，得到成功 %d 个、拒绝 %d 个", success, rejected)
	}
}

// TestRotateSessionCASAllowsOneWinner 核对存储层的 CAS：并发轮换同一会话只有
// 一个成功，其余返回 ErrInvalidToken。
func TestRotateSessionCASAllowsOneWinner(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	reg, err := s.Register(ctx, "a@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	st := s.store.(*MemoryStore)
	sess, err := st.SessionByAccessHash(ctx, hashToken(reg.AccessToken))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	var wins int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			err := st.RotateSession(ctx, sess.ID, sess.RefreshHash,
				fmt.Sprintf("access-%d", i), fmt.Sprintf("refresh-%d", i),
				now.Add(time.Hour), now.Add(24*time.Hour))
			switch {
			case err == nil:
				atomic.AddInt32(&wins, 1)
			case !errors.Is(err, ErrInvalidToken):
				t.Errorf("并发轮换返回了意外的错误: %v", err)
			}
		}(i)
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("并发 CAS 应当只有一个成功，实际 %d 个", wins)
	}
}
