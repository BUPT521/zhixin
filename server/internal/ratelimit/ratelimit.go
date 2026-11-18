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

// Limiter 是一组按键分开的令牌桶，空闲的键会被回收。
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*entry
	limit   rate.Limit
	burst   int
	// idle 是键多久不用就回收；为零时不回收。
	idle  time.Duration
	nowFn func() time.Time
}

type entry struct {
	bucket *rate.Limiter
	seen   time.Time
}

// New 建一个限流器：每秒补充 limit 个令牌，最多积到 burst 个。
func New(limit rate.Limit, burst int, idle time.Duration) *Limiter {
	if burst < 1 {
		burst = 1
	}
	return &Limiter{
		buckets: map[string]*entry{},
		limit:   limit,
		burst:   burst,
		idle:    idle,
		nowFn:   time.Now,
	}
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
	l.reap(now)
	buckets := make([]*rate.Limiter, 0, len(keys))
	for _, key := range keys {
		e, ok := l.buckets[key]
		if !ok {
			e = &entry{bucket: rate.NewLimiter(l.limit, l.burst)}
			l.buckets[key] = e
		}
		e.seen = now
		// TokensAt 按传入时间算，时钟因此可控，测试可以模拟令牌补充。
		if tokens := e.bucket.TokensAt(now); tokens < 1 {
			seconds := math.Ceil((1 - tokens) / float64(l.limit))
			if seconds >= math.MaxInt64 {
				return math.MaxInt64
			}
			return int64(seconds)
		}
		buckets = append(buckets, e.bucket)
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

// reap 回收长时间没用的键，避免按地址限流时表无限增长。
func (l *Limiter) reap(now time.Time) {
	if l.idle <= 0 {
		return
	}
	for key, e := range l.buckets {
		if now.Sub(e.seen) > l.idle {
			delete(l.buckets, key)
		}
	}
}

// Len 报告当前保留的键数，供测试核对回收。
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
