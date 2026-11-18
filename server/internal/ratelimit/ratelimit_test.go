package ratelimit

import (
	"fmt"
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

// TestReapRunsAtMostEveryQuarterIdle 守住清理节奏：全表回收最多每 idle/4 一次，
// 不是每次 Take 都扫一遍。
func TestReapRunsAtMostEveryQuarterIdle(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(1), 1, 4*time.Minute)
	l.nowFn = func() time.Time { return now }
	l.lastReap = now
	// 放一个空闲时间已超过 idle 的键，只有回收真正执行时才会被删。
	l.buckets["old"] = &entry{bucket: rate.NewLimiter(rate.Limit(1), 1), seen: now.Add(-5 * time.Minute)}

	now = now.Add(10 * time.Second) // 不足 idle/4（1 分钟）
	if l.Take("a") != 0 {
		t.Fatal("新键第一次应当放行")
	}
	if l.Len() != 2 {
		t.Fatalf("不足 idle/4 时不该扫表，得到 %d 个键", l.Len())
	}

	now = now.Add(55 * time.Second) // 距上次回收 65 秒，超过 idle/4
	if l.Take("b") != 0 {
		t.Fatal("新键第一次应当放行")
	}
	if _, ok := l.buckets["old"]; ok {
		t.Fatal("到期后应当按 idle/4 的节奏回收空闲键")
	}
	if l.Len() != 2 {
		t.Fatalf("回收后应只剩 a 与 b，得到 %d 个键", l.Len())
	}
}

// TestMaxKeysEvictsLeastRecentlyUsed 守住键数上限：到上限且没有可回收的空闲键时，
// 淘汰最久没用到的键，新请求仍然能建桶。
func TestMaxKeysEvictsLeastRecentlyUsed(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(0), 1, 0, 2)
	l.nowFn = func() time.Time { return now }
	take := func(key string) {
		t.Helper()
		if l.Take(key) != 0 {
			t.Fatalf("%s 第一次应当放行", key)
		}
	}
	take("a")
	now = now.Add(time.Second)
	take("b")
	now = now.Add(time.Second)
	take("c") // 到上限，a 最久未用

	if l.Len() != 2 {
		t.Fatalf("键数应保持在上限，得到 %d", l.Len())
	}
	if _, ok := l.buckets["a"]; ok {
		t.Fatal("最久未用的 a 应被淘汰")
	}
	if _, ok := l.buckets["b"]; !ok {
		t.Fatal("b 不该被淘汰")
	}
	if _, ok := l.buckets["c"]; !ok {
		t.Fatal("新键 c 应当保留")
	}
}

// TestMaxKeysCleanupHappensBeforeEviction 核对到达上限时先按 idle/4 规则清理空闲
// 键，清理腾出空间就不再淘汰仍在使用的键。
func TestMaxKeysCleanupHappensBeforeEviction(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(0), 1, 4*time.Minute, 1)
	l.nowFn = func() time.Time { return now }
	l.lastReap = now
	if l.Take("stale") != 0 {
		t.Fatal("stale 第一次应当放行")
	}
	now = now.Add(5 * time.Minute) // 超过 idle，且距上次回收超过 idle/4
	if l.Take("fresh") != 0 {
		t.Fatal("新键第一次应当放行")
	}
	if _, ok := l.buckets["stale"]; ok {
		t.Fatal("到上限时应先清理空闲键，而不是直接淘汰")
	}
	if _, ok := l.buckets["fresh"]; !ok {
		t.Fatal("清理腾出空间后新键应保留")
	}
	if l.Len() != 1 {
		t.Fatalf("键数应为 1，得到 %d", l.Len())
	}
}

// TestMaxKeysBoundsGrowth 守住表不会无限增长：连续访问大量不同的键之后，保留的
// 键数不超过上限。
func TestMaxKeysBoundsGrowth(t *testing.T) {
	l := New(rate.Limit(0), 1, 0, 5)
	for i := 0; i < 1000; i++ {
		l.Take(fmt.Sprintf("key-%d", i))
	}
	if l.Len() != 5 {
		t.Fatalf("键数应停在上限 5，得到 %d", l.Len())
	}
}

// TestWouldBlockDoesNotConsume 核对预检查不扣令牌：报告需要等待之后，桶的状态与
// 没问过一样，别的键也不受影响。
func TestWouldBlockDoesNotConsume(t *testing.T) {
	now := time.Now()
	l := New(rate.Limit(0.5), 1, 0)
	l.nowFn = func() time.Time { return now }

	if wait := l.WouldBlock("a"); wait != 0 {
		t.Fatalf("还没用过的键不该报告等待，得到 %d", wait)
	}
	if l.Take("a") != 0 {
		t.Fatal("a 第一次应当放行")
	}
	wait := l.WouldBlock("a")
	if wait <= 0 {
		t.Fatal("用完令牌的键应报告等待")
	}
	// 非消费：再问一次结果不变，说明没有扣令牌。
	if again := l.WouldBlock("a"); again != wait {
		t.Fatalf("预检查不应改变桶的状态，得到 %d 与 %d", wait, again)
	}
	// 别的键不受影响。
	if l.Take("b") != 0 {
		t.Fatal("b 第一次应当放行")
	}
	now = now.Add(2 * time.Second) // 每秒补 0.5 个，两秒补回一个
	if wait := l.WouldBlock("a"); wait != 0 {
		t.Fatalf("令牌补回后不该再报告等待，得到 %d", wait)
	}
}
