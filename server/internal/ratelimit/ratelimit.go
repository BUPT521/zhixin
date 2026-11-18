// Package ratelimit 按来源地址与账号做进程内限流（ADR-0015 第 5 条）。
//
// 登录与注册按来源地址限流，刷新令牌按账号与来源地址同时限流，防止同一账号被
// 并发尝试。状态保存在进程内存里，单实例部署够用；多实例部署时是否共享另行决定。
package ratelimit

import (
	"math"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Limiter 是一组按键分开的令牌桶，空闲的键会被回收，键的数量有上限。
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*entry
	limit   rate.Limit
	burst   int
	// idle 是键多久不用就回收；为零时不回收。
	idle time.Duration
	// maxKeys 是保留的键数上限；为零时不设上限。
	maxKeys int
	// lastReap 是上一次全表回收的时间。清理最多每 idle/4 一次，避免每次 Take
	// 都扫一遍表：按来源地址限流时表可以很大，逐个请求扫表会变成 CPU 热点。
	lastReap time.Time
	nowFn    func() time.Time
}

type entry struct {
	bucket *rate.Limiter
	seen   time.Time
}

// New 建一个限流器：每秒补充 limit 个令牌，最多积到 burst 个。idle 是键多久不用
// 就回收，为零时不回收。maxKeys 可选，给出时是保留的键数上限：到达上限先按
// idle/4 的节奏清理空闲键，仍然满就淘汰最久未用的键，表不会随请求无限增长。
func New(limit rate.Limit, burst int, idle time.Duration, maxKeys ...int) *Limiter {
	if burst < 1 {
		burst = 1
	}
	l := &Limiter{
		buckets: map[string]*entry{},
		limit:   limit,
		burst:   burst,
		idle:    idle,
		nowFn:   time.Now,
	}
	if len(maxKeys) > 0 && maxKeys[0] > 0 {
		l.maxKeys = maxKeys[0]
	}
	l.lastReap = l.nowFn()
	return l
}

// Disabled 返回一个永远放行的限流器，用于关闭限流或测试。
func Disabled() *Limiter { return New(rate.Inf, 1, 0) }

// Take consumes a token per key, or returns the seconds until a retry.
func (l *Limiter) Take(keys ...string) int64 { return l.check(true, keys) }

// WouldBlock 只检查这些键当前是否还有令牌，不消费；返回 0 表示可以继续。
//
// 登录失败预算要“先看再做”：校验密码本身要花 CPU 和内存，超限的请求应当在校验
// 之前就回 429，所以检查不能扣令牌，令牌只在校验失败之后由调用方 Take 扣掉。
func (l *Limiter) WouldBlock(keys ...string) int64 { return l.check(false, keys) }

// check 是所有按键判定的共同实现；take 为假时只看不扣。
func (l *Limiter) check(take bool, keys []string) int64 {
	if len(keys) == 0 {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.nowFn()
	l.reapIfDue(now)
	buckets := make([]*rate.Limiter, 0, len(keys))
	for _, key := range keys {
		bucket := l.bucketFor(key, now)
		// TokensAt 按传入时间算，时钟因此可控，测试可以模拟令牌补充。
		if tokens := bucket.TokensAt(now); tokens < 1 {
			return retryAfter(tokens, l.limit)
		}
		buckets = append(buckets, bucket)
	}
	for _, b := range buckets {
		if !take {
			continue
		}
		// 上一步已经确认都还有令牌，这里一定成功；非阻塞，不占请求时间。
		_ = b.AllowN(now, 1)
	}
	return 0
}

// bucketFor 取或建一个键的令牌桶，负责在上限处清理与淘汰。
func (l *Limiter) bucketFor(key string, now time.Time) *rate.Limiter {
	if e, ok := l.buckets[key]; ok {
		e.seen = now
		return e.bucket
	}
	if l.maxKeys > 0 && len(l.buckets) >= l.maxKeys {
		// 到上限时先按空闲回收的节奏清一次，仍然满再淘汰最久未用的键。
		l.reapIfDue(now)
		if len(l.buckets) >= l.maxKeys {
			l.evictOldest()
		}
	}
	e := &entry{bucket: rate.NewLimiter(l.limit, l.burst), seen: now}
	l.buckets[key] = e
	return e.bucket
}

// reapIfDue 按 idle/4 的节奏回收空闲键；清理本身是 O(表大小)，不能让每次 Take
// 都付这个代价。
func (l *Limiter) reapIfDue(now time.Time) {
	if l.idle <= 0 {
		return
	}
	interval := l.idle / 4
	if interval <= 0 {
		interval = l.idle
	}
	if now.Sub(l.lastReap) < interval {
		return
	}
	l.lastReap = now
	l.reap(now)
}

// reap 回收长时间没用的键，避免按地址限流时表无限增长。
func (l *Limiter) reap(now time.Time) {
	for key, e := range l.buckets {
		if now.Sub(e.seen) > l.idle {
			delete(l.buckets, key)
		}
	}
}

// evictOldest 删除最久没有用到的键，只在到达键数上限、且清理没有腾出空间时调用。
func (l *Limiter) evictOldest() {
	var oldestKey string
	var oldest time.Time
	for key, e := range l.buckets {
		if oldestKey == "" || e.seen.Before(oldest) {
			oldestKey, oldest = key, e.seen
		}
	}
	if oldestKey != "" {
		delete(l.buckets, oldestKey)
	}
}

// retryAfter 由剩余令牌数与补充速率算出建议等待的整秒数。速率为 0 时令牌不会
// 补充，返回最大等待，让调用方按“暂时不可用”处理而不是立刻重试。
func retryAfter(tokens float64, limit rate.Limit) int64 {
	seconds := math.Ceil((1 - tokens) / float64(limit))
	if math.IsNaN(seconds) || seconds >= math.MaxInt64 {
		return math.MaxInt64
	}
	if seconds < 1 {
		return 1
	}
	return int64(seconds)
}

// Len 报告当前保留的键数，供测试核对回收。
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
