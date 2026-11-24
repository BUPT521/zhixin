package llmproxy

import "sync"

// byteBudget 是实例级的在途字节预算。托管请求在读取请求体之前按请求体大小预留，
// 非流式响应与嵌入批次在读取之前再按响应上限预留，占不到预算时请求在写出任何内容
// 之前就被拒绝。并发因此由字节数推导，不再随账号数量线性上涨，Go 堆的上限与
// nginx 的连接数上限也不必是同一个数量级（ADR-0036）。
//
// 预算分成两份：全部容量留给前台，后台（材料导入与索引补算）另有一份占比上限，
// 所以前台请求增长时先压缩后台批次，后台不会被前台挤掉之后连一个批次都跑不动。
type byteBudget struct {
	mu       sync.Mutex
	capacity int64
	// backgroundCapacity 是后台最多占用的字节数；小于等于 0 表示不单独限制。
	backgroundCapacity int64
	used               int64
	backgroundUsed     int64
}

// newByteBudget 建一份容量为 capacity 的预算；小于等于 0 表示不限制。
func newByteBudget(capacity int64) *byteBudget {
	return &byteBudget{capacity: capacity}
}

// withBackgroundShare 按百分比给后台划一份上限：percent 取 0 到 100，100 表示
// 后台不单独限制；容量不限时同样不限制。返回预算本身，便于装配时链式调用。
func (b *byteBudget) withBackgroundShare(percent int) *byteBudget {
	if b == nil || b.capacity <= 0 || percent <= 0 || percent >= 100 {
		return b
	}
	b.backgroundCapacity = b.capacity * int64(percent) / 100
	return b
}

// reserve 在还有余量时占 n 个字节，返回的 release 在请求结束时调用一次。余量不足
// 时返回 nil 与 false，调用方据此回 429，不排队等待：托管请求的耗时可到几分钟，
// 排队只会把内存压力换成 goroutine 积压。
func (b *byteBudget) reserve(n int64) (release func(), ok bool) {
	return b.reserveWorkload(n, false)
}

// reserveWorkload 与 reserve 相同，background 为真时同时受后台占比约束。
func (b *byteBudget) reserveWorkload(n int64, background bool) (release func(), ok bool) {
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
	if background && b.backgroundCapacity > 0 && b.backgroundUsed+n > b.backgroundCapacity {
		return nil, false
	}
	b.used += n
	if background {
		b.backgroundUsed += n
	}
	return func() {
		b.mu.Lock()
		b.used -= n
		if background {
			b.backgroundUsed -= n
		}
		b.mu.Unlock()
	}, true
}

// inUse 返回当前已占用的字节数，供同包用例核对归还与上限。
func (b *byteBudget) inUse() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.used
}

// backgroundInUse 返回后台已占用的字节数，供同包用例核对占比上限。
func (b *byteBudget) backgroundInUse() int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.backgroundUsed
}
