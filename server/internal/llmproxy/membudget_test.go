package llmproxy

import (
	"net/http"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/config"
)

// TestByteBudgetReserve 核对实例字节预算：余量够时占用成功，不足时拒绝，归还
// 之后恢复；容量为 0 表示不限制，占多少都不拒绝。
func TestByteBudgetReserve(t *testing.T) {
	b := newByteBudget(100)
	release1, ok := b.reserve(60)
	if !ok || b.inUse() != 60 {
		t.Fatalf("第一份 60 应占到，得到 %v %d", ok, b.inUse())
	}
	release2, ok := b.reserve(50)
	if ok || release2 != nil || b.inUse() != 60 {
		t.Fatalf("余量只有 40，50 应被拒绝且不改变用量，得到 %v %d", ok, b.inUse())
	}
	if _, ok := b.reserve(40); !ok {
		t.Fatal("余量 40 应能占到")
	}
	if _, ok := b.reserve(1); ok {
		t.Fatal("预算用完之后不应再占到")
	}
	release1()
	if b.inUse() != 40 {
		t.Fatalf("归还 60 之后应剩 40，得到 %d", b.inUse())
	}

	unlimited := newByteBudget(0)
	if _, ok := unlimited.reserve(1 << 40); !ok {
		t.Fatal("容量为 0 表示不限制，任意大小都应放行")
	}
}

// TestRequestBytes 核对请求体在实例预算里的占用：按声明长度算两份，长度未知或
// 超过上限时按上限算，客户端不能靠少写 Content-Length 少占预算。
func TestRequestBytes(t *testing.T) {
	p := &Proxy{cfg: config.LLMConfig{MaxRequestBytes: 1000}}
	cases := []struct {
		length int64
		want   int64
	}{
		{length: 10, want: 20},
		{length: 5000, want: 2000}, // 超过上限时按上限
		{length: -1, want: 2000},   // chunked 没有声明长度
		{length: 0, want: 0},
	}
	for _, c := range cases {
		r := &http.Request{ContentLength: c.length}
		if got := p.requestBytes(r); got != c.want {
			t.Fatalf("Content-Length %d 应占 %d 字节，得到 %d", c.length, c.want, got)
		}
	}
}

// TestChunkAllowance 核对嵌入各批共享的响应字节额度：合计到达上限之后返回 0，
// 接到响应体上的读取器据此按响应过大处理，不会先读进内存再判断。
func TestChunkAllowance(t *testing.T) {
	a := newChunkAllowance(100)
	if got := a.take(60); got != 60 {
		t.Fatalf("第一轮应给出 60，得到 %d", got)
	}
	if got := a.take(60); got != 40 {
		t.Fatalf("第二轮只剩 40，得到 %d", got)
	}
	if got := a.take(10); got != 0 {
		t.Fatalf("额度用完应返回 0，得到 %d", got)
	}
	if _, err := readResponse(allowanceReader{r: strings.NewReader("0123456789"), a: newChunkAllowance(5)}, 16); err != errResponseTooLarge {
		t.Fatalf("超过共享额度应返回 errResponseTooLarge，得到 %v", err)
	}
	if got, err := readResponse(allowanceReader{r: strings.NewReader("0123456789"), a: newChunkAllowance(10)}, 16); err != nil || string(got) != "0123456789" {
		t.Fatalf("额度够时应读完，得到 %q %v", got, err)
	}
}
