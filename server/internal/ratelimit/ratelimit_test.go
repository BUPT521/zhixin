package ratelimit

import (
	"sync"
	"testing"
	"time"

	"golang.org/x/time/rate"
)

func TestTakeConsumesAndRefills(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(1), 2, 0) // 每秒 1 个，最多积 2 个
	l.nowFn = func() time.Time { return now }

	if l.Take("a") != 0 || l.Take("a") != 0 {
		t.Fatal("前两次应当放行")
	}
	if l.Take("a") == 0 {
		t.Fatal("令牌用完应当拒绝")
	}
	if l.Take("b") != 0 {
		t.Fatal("不同键之间互不影响")
	}

	now = now.Add(time.Second)
	if l.Take("a") != 0 {
		t.Fatal("过一秒应当补回一个令牌")
	}
}

func TestTakeChecksAllKeysBeforeConsuming(t *testing.T) {
	now := time.Now()
	// rate 0 表示不补充，只看初始的 burst 令牌，判定不受真实时钟影响。
	l := New(rate.Limit(0), 1, 0)
	l.nowFn = func() time.Time { return now }

	if l.Take("y") != 0 {
		t.Fatal("y 第一次应当放行")
	}
	// y 已用完；这次请求整体应当拒绝，且不能把 x 的令牌扣掉。
	if l.Take("x", "y") == 0 {
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

	l.Take("a")
	if l.Len() != 1 {
		t.Fatalf("应保留 1 个键，得到 %d", l.Len())
	}
	now = now.Add(2 * time.Minute)
	l.Take("b")
	if l.Len() != 1 {
		t.Fatalf("空闲键应被回收，只剩 b，得到 %d", l.Len())
	}
	if _, ok := l.buckets["b"]; !ok {
		t.Fatal("新键应当保留")
	}
}

func TestDisabledAlwaysTakes(t *testing.T) {
	l := Disabled()
	for i := 0; i < 100; i++ {
		if l.Take("a") != 0 {
			t.Fatal("关闭限流后应一律放行")
		}
	}
}

// TestWouldBlockDoesNotConsume 守住“先检查再决定”的语义：检查本身不扣令牌，
// 只有检查通过后调用 Take 才扣。
func TestWouldBlockDoesNotConsume(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(0), 1, 0) // 不补充，只看初始的 burst 令牌
	l.nowFn = func() time.Time { return now }

	for i := 0; i < 3; i++ {
		if delay := l.WouldBlock("a"); delay != 0 {
			t.Fatalf("第 %d 次检查应当放行，得到 %d 秒", i+1, delay)
		}
	}
	if l.Take("a") != 0 {
		t.Fatal("检查之后第一次 Take 应当成功")
	}
	if delay := l.WouldBlock("a"); delay == 0 {
		t.Fatal("令牌用完之后的检查应当拒绝")
	}
}

func TestWouldBlockChecksAllKeys(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(0), 1, 0)
	l.nowFn = func() time.Time { return now }
	l.Take("used")
	if l.WouldBlock("free", "used") == 0 {
		t.Fatal("任一键用完时整个检查应当拒绝")
	}
	if l.WouldBlock("free") != 0 {
		t.Fatal("检查不应扣减其他键的令牌")
	}
}

func TestConcurrentTakeIsSafe(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(1000), 100, 0)
	l.nowFn = func() time.Time { return now }
	var wg sync.WaitGroup
	allowed := make(chan int, 200)
	for i := 0; i < 200; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Take("a") == 0 {
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
