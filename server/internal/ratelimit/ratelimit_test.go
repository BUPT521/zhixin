package ratelimit

import (
	"sync"
	"testing"
	"time"

	"golang.org/x/time/rate"
)

func TestAllowConsumesAndRefills(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(1), 2, 0) // 每秒 1 个，最多积 2 个
	l.nowFn = func() time.Time { return now }

	if !l.Allow("a") || !l.Allow("a") {
		t.Fatal("前两次应当放行")
	}
	if l.Allow("a") {
		t.Fatal("令牌用完应当拒绝")
	}
	if !l.Allow("b") {
		t.Fatal("不同键之间互不影响")
	}

	now = now.Add(time.Second)
	if !l.Allow("a") {
		t.Fatal("过一秒应当补回一个令牌")
	}
}

func TestAllowChecksAllKeysBeforeConsuming(t *testing.T) {
	now := time.Now()
	// rate 0 表示不补充，只看初始的 burst 令牌，判定不受真实时钟影响。
	l := New(rate.Limit(0), 1, 0)
	l.nowFn = func() time.Time { return now }

	if !l.Allow("y") {
		t.Fatal("y 第一次应当放行")
	}
	// y 已用完；这次请求整体应当拒绝，且不能把 x 的令牌扣掉。
	if l.Allow("x", "y") {
		t.Fatal("任一键用完时整个请求应当拒绝")
	}
	if got := l.buckets["x"].bucket.TokensAt(now); got < 1 {
		t.Fatalf("拒绝时不应扣减其他键的令牌，x 剩余 %v", got)
	}
}

func TestReapDropsIdleKeys(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(1), 1, time.Minute)
	l.nowFn = func() time.Time { return now }

	l.Allow("a")
	if l.Len() != 1 {
		t.Fatalf("应保留 1 个键，得到 %d", l.Len())
	}
	now = now.Add(2 * time.Minute)
	l.Allow("b")
	if l.Len() != 1 {
		t.Fatalf("空闲键应被回收，只剩 b，得到 %d", l.Len())
	}
	if _, ok := l.buckets["b"]; !ok {
		t.Fatal("新键应当保留")
	}
}

func TestDisabledAlwaysAllows(t *testing.T) {
	l := Disabled()
	for i := 0; i < 100; i++ {
		if !l.Allow("a") {
			t.Fatal("关闭限流后应一律放行")
		}
	}
}

func TestConcurrentAllowIsSafe(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(1000), 100, 0)
	l.nowFn = func() time.Time { return now }
	var wg sync.WaitGroup
	allowed := make(chan int, 200)
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Allow("a") {
				allowed <- 1
			}
		}()
	}
	wg.Wait()
	close(allowed)
	count := 0
	for range allowed {
		count++
	}
	if count != 100 {
		t.Fatalf("放行次数应等于 burst，得到 %d", count)
	}
}
