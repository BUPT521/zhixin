// Package ratelimit 按来源地址与账号做进程内限流（ADR-0015 第 5 条）。
//
// 登录与注册按来源地址限流，刷新令牌按账号与来源地址同时限流，防止同一账号被
// 并发尝试。状态保存在进程内存里，单实例部署够用；多实例部署时是否共享另行决定。
package ratelimit

import (
	"container/list"
	"math"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Limiter 是一组按键分开的令牌桶，空闲的键会被回收，键的数量有上限。
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*entry
	// order 按最近一次使用排列：表头是最久没用的键，表尾是刚用过的键。到达键数
	// 上限时从表头淘汰一个键，回收空闲键时也从表头往后走，两者都不再扫全表。
	order *list.List
	limit rate.Limit
	burst int
	// idle 是键多久不用就回收；为零时不回收。
	idle time.Duration
	// maxKeys 是保留的键数上限；New 总会给出一个正值，表不会无限增长。
	maxKeys int
	// lastReap 是上一次全表回收的时间。清理最多每 idle/4 一次，避免每次 Take
	// 都扫一遍表：按来源地址限流时表可以很大，逐个请求扫表会变成 CPU 热点。
	lastReap time.Time
	nowFn    func() time.Time
	// disabled 表示关闭限流：判定直接放行，不建桶。
	disabled bool
}

type entry struct {
	key    string
	tokens float64
	seen   time.Time
	elem   *list.Element
}

// defaultMaxKeys 是调用方没有给出键数上限时保留的桶数。取与配置层
// ZHIXIN_RATE_LIMIT_KEYS 默认值相同的 100000：漏传上限不再静默退化成无上限的
// map，按来源地址分桶的表仍然有边界（S32）。
const defaultMaxKeys = 100000

// New 建一个限流器：每秒补充 limit 个令牌，最多积到 burst 个。idle 是键多久不用
// 就回收，为零时不回收。maxKeys 可选，给出正值时是保留的键数上限：到达上限先按
// idle/4 的节奏清理空闲键，仍然满就淘汰最久未用的键。漏传或传非正值时使用
// defaultMaxKeys，表不会随请求无限增长。
func New(limit rate.Limit, burst int, idle time.Duration, maxKeys ...int) *Limiter {
	if burst < 1 {
		burst = 1
	}
	keys := defaultMaxKeys
	if len(maxKeys) > 0 && maxKeys[0] > 0 {
		keys = maxKeys[0]
	}
	l := &Limiter{
		buckets: map[string]*entry{},
		order:   list.New(),
		limit:   limit,
		burst:   burst,
		idle:    idle,
		maxKeys: keys,
		nowFn:   time.Now,
	}
	l.lastReap = l.nowFn()
	return l
}

// Limit 是补充速率与桶容量，供按实例总量控制的桶从配置读取。
type Limit struct {
	PerSecond float64
	Burst     int
}

// NewGlobal 建一个整个实例共用的限流器：所有请求扣同一个键，用来给换地址也
// 绕不过去的总量兜底，比如发信。速率为零或负数时返回 Disabled，关闭限流。
func NewGlobal(l Limit) *Limiter {
	if l.PerSecond <= 0 {
		return Disabled()
	}
	return New(rate.Limit(l.PerSecond), l.Burst, 15*time.Minute, 1)
}

// Disabled 返回一个永远放行的限流器，用于关闭限流或测试。它不建桶，判定也不
// 占内存：运维把限流速率设成 0 之后，随机标识符不会再让每个请求留下一个桶。
func Disabled() *Limiter { return &Limiter{disabled: true, limit: rate.Inf, burst: 1} }

// TakeOne 扣掉全局桶里的一个令牌，返回建议等待的秒数；0 表示放行。
func (l *Limiter) TakeOne() int64 { return l.Take("global") }

// Take consumes a token per key, or returns the seconds until a retry.
func (l *Limiter) Take(keys ...string) int64 { return l.check(true, keys) }

// WouldBlock 只检查这些键当前是否还有令牌，不消费；返回 0 表示可以继续。
func (l *Limiter) WouldBlock(keys ...string) int64 { return l.check(false, keys) }

// TakeRefundable 在开始密码校验前扣除一个令牌。退款只作用于这一次扣减所属的桶，
// 已被回收的桶不会因较早的退款重新创建。
func (l *Limiter) TakeRefundable(key string) (refund func(), delay int64) {
	if l.disabled {
		return func() {}, 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.nowFn()
	l.reapIfDue(now)
	bucket := l.bucketFor(key, now)
	if bucket.tokens < 1 {
		return nil, retryAfter(bucket.tokens, l.limit)
	}
	bucket.tokens--
	return sync.OnceFunc(func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if l.buckets[key] == bucket {
			l.refill(bucket, l.nowFn())
			l.order.MoveToBack(bucket.elem)
			bucket.tokens = min(float64(l.burst), bucket.tokens+1)
		}
	}), 0
}

// check 是所有按键判定的共同实现；take 为假时只看不扣。
func (l *Limiter) check(take bool, keys []string) int64 {
	if l.disabled || len(keys) == 0 {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.nowFn()
	l.reapIfDue(now)
	buckets := make([]*entry, 0, len(keys))
	for _, key := range keys {
		bucket := l.bucketFor(key, now)
		if tokens := bucket.tokens; tokens < 1 {
			return retryAfter(tokens, l.limit)
		}
		buckets = append(buckets, bucket)
	}
	for _, b := range buckets {
		if !take {
			continue
		}
		b.tokens--
	}
	return 0
}

// bucketFor 取或建一个键的令牌桶，负责在上限处清理与淘汰。
func (l *Limiter) bucketFor(key string, now time.Time) *entry {
	if e, ok := l.buckets[key]; ok {
		l.refill(e, now)
		l.order.MoveToBack(e.elem)
		return e
	}
	if l.maxKeys > 0 && len(l.buckets) >= l.maxKeys {
		// 到上限时先按空闲回收的节奏清一次，仍然满再淘汰最久未用的键。
		l.reapIfDue(now)
		if len(l.buckets) >= l.maxKeys {
			l.evictOldest()
		}
	}
	e := &entry{key: key, tokens: float64(l.burst), seen: now}
	e.elem = l.order.PushBack(e)
	l.buckets[key] = e
	return e
}

func (l *Limiter) refill(e *entry, now time.Time) {
	if l.limit == rate.Inf {
		e.tokens = float64(l.burst)
	} else if now.After(e.seen) {
		e.tokens = min(float64(l.burst), e.tokens+now.Sub(e.seen).Seconds()*float64(l.limit))
	}
	e.seen = now
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

// reap 从最久没用的键开始回收，遇到仍在使用的键就停：order 按最近使用排列，
// 后面的键只会更新，所以不需要遍历全表。
func (l *Limiter) reap(now time.Time) {
	for {
		front := l.order.Front()
		if front == nil {
			return
		}
		e := front.Value.(*entry)
		if now.Sub(e.seen) <= l.idle {
			return
		}
		l.remove(e)
	}
}

// evictOldest 删除最久没有用到的键，只在到达键数上限、且清理没有腾出空间时
// 调用。order 的表头就是最久未用的键，淘汰不再扫全表。
func (l *Limiter) evictOldest() {
	if front := l.order.Front(); front != nil {
		l.remove(front.Value.(*entry))
	}
}

// remove 把键从表与顺序里一起删掉。
func (l *Limiter) remove(e *entry) {
	delete(l.buckets, e.key)
	l.order.Remove(e.elem)
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
