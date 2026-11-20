package llmproxy

import "sync"

// byteBudget 是实例级的在途字节预算。托管请求在读取请求体之前按请求体大小预留，
// 非流式响应与嵌入批次在读取之前再按响应上限预留，占不到预算时请求在写出任何内容
// 之前就被拒绝。并发因此由字节数推导，不再随账号数量线性上涨，Go 堆的上限与
// nginx 的连接数上限也不必是同一个数量级（ADR-0036）。
type byteBudget struct {
	mu       sync.Mutex
	capacity int64
	used     int64
}

// newByteBudget 建一份容量为 capacity 的预算；小于等于 0 表示不限制。
func newByteBudget(capacity int64) *byteBudget {
	return &byteBudget{capacity: capacity}
}

// reserve 在还有余量时占 n 个字节，返回的 release 在请求结束时调用一次。余量不足
// 时返回 nil 与 false，调用方据此回 429，不排队等待：托管请求的耗时可到几分钟，
// 排队只会把内存压力换成 goroutine 积压。
func (b *byteBudget) reserve(n int64) (release func(), ok bool) {
	if b == nil || b.capacity <= 0 {
		return func() {}, true
	}
	if n < 0 {
		n = 0
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.used+n > b.capacity {
		return nil, false
	}
	b.used += n
	return func() {
		b.mu.Lock()
		b.used -= n
		b.mu.Unlock()
	}, true
}

// inUse 返回当前已占用的字节数，供同包用例核对归还与上限。
func (b *byteBudget) inUse() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.used
}
