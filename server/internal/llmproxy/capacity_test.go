package llmproxy

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// workloadHeaders 是嵌入请求的工作负载头；batch 表示材料导入与索引补算。
func workloadHeaders(workload string) map[string]string {
	return map[string]string{
		"Content-Type":      "application/json",
		"X-Zhixin-Workload": workload,
	}
}

// TestForegroundReservedSlots 核对账号层的名额保留：后台批次只能用并发上限减去
// 保留名额的部分，前台请求仍可用满并发上限；两个计数各自归还，不互相影响。
func TestForegroundReservedSlots(t *testing.T) {
	cfg := baseConfig()
	cfg.ForegroundReserved = 2
	env := newTestServer(t, cfg, nil)
	p := env.proxy
	p.SetConcurrencyLimit(4)

	for i := range 2 {
		if !p.acquireConcurrency("u", true) {
			t.Fatalf("第 %d 个后台请求应占得到名额", i+1)
		}
	}
	if p.acquireConcurrency("u", true) {
		t.Fatal("第三个后台请求应被保留名额挡下")
	}
	for i := range 2 {
		if !p.acquireConcurrency("u", false) {
			t.Fatalf("第 %d 个前台请求应占得到名额", i+1)
		}
	}
	if p.acquireConcurrency("u", false) {
		t.Fatal("前台请求合计达到并发上限后应被拒绝")
	}

	// 归还一个前台名额之后，后台仍然被自己的上限挡住，前台立即恢复可用。
	p.releaseConcurrency("u", false)
	if p.acquireConcurrency("u", true) {
		t.Fatal("后台名额没有随前台归还可变多")
	}
	if !p.acquireConcurrency("u", false) {
		t.Fatal("归还之后前台应能重新占名额")
	}

	p.releaseConcurrency("u", false)
	p.releaseConcurrency("u", false)
	p.releaseConcurrency("u", true)
	p.releaseConcurrency("u", true)
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.inflight) != 0 || len(p.background) != 0 {
		t.Fatalf("名额全部归还之后不应留下空项：%v", p.inflight)
	}
}

// TestByteBudgetBackgroundShare 核对实例内存预算的占比：后台只能占约定比例，
// 前台仍可用满整个预算，两部分分别计数并在归还时去掉。
func TestByteBudgetBackgroundShare(t *testing.T) {
	b := newByteBudget(100).withBackgroundShare(60)
	releaseBackground, ok := b.reserveWorkload(60, true)
	if !ok || b.backgroundInUse() != 60 {
		t.Fatalf("后台应能占到 60 字节，得到 %v %d", ok, b.backgroundInUse())
	}
	if _, ok := b.reserveWorkload(10, true); ok {
		t.Fatal("后台超过占比上限应被拒绝")
	}
	releaseForeground, ok := b.reserveWorkload(40, false)
	if !ok || b.inUse() != 100 {
		t.Fatalf("前台应能用满剩余预算，得到 %v %d", ok, b.inUse())
	}
	if _, ok := b.reserve(1); ok {
		t.Fatal("总预算用完之后应拒绝")
	}
	releaseForeground()
	releaseBackground()
	if b.inUse() != 0 || b.backgroundInUse() != 0 {
		t.Fatalf("归还之后应清零，得到 %d %d", b.inUse(), b.backgroundInUse())
	}
}

// TestBackgroundEmbeddingsYieldToForeground 核对后台嵌入批次在账号名额用完时
// 收到 429，而聊天不受影响；后台批次结束后容量重新可用。
func TestBackgroundEmbeddingsYieldToForeground(t *testing.T) {
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	var block atomic.Bool
	block.Store(true)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/embeddings") {
			if block.Load() {
				started <- struct{}{}
				select {
				case <-release:
				case <-time.After(5 * time.Second):
				}
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"object":"list","data":[{"object":"embedding","index":0,"embedding":[0.1]}],"usage":{"prompt_tokens":2,"total_tokens":2}}`)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"total_tokens":5}}`)
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", upstream.URL, "k")
		putModel(t, c, ModelRecord{Name: "chat", Kind: KindChat, Routes: []Route{{ProviderID: "p", UpstreamModel: "chat"}}})
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Routes: []Route{{ProviderID: "p", UpstreamModel: "emb"}}})
	})
	env.proxy.SetConcurrencyLimit(2)
	env.proxy.cfg.ForegroundReserved = 1
	token := signIn(t, env.authSvc, "capacity@b.cn")

	embedBody := []byte(`{"model":"emb","input":["text-1"]}`)
	done := make(chan int, 1)
	go func() {
		resp := env.c.Do(http.MethodPost, "/v1/llm/embeddings", token,
			bytes.NewReader(embedBody), workloadHeaders("batch"))
		defer resp.Body.Close()
		done <- resp.StatusCode
	}()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("后台嵌入请求没有到达来源")
	}

	// 后台名额已经用完：第二个批次被 429 挡在读取请求体之前。
	resp := env.c.Do(http.MethodPost, "/v1/llm/embeddings", token,
		bytes.NewReader(embedBody), workloadHeaders("batch"))
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("后台批次应让出名额并回 429，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 聊天是前台请求，后台占用一个名额之后仍能进行。
	chatReq := []byte(`{"model":"chat","input":[{"type":"message","role":"user","content":"hi"}]}`)
	resp = env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatReq), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("前台聊天不应被后台批次挡住，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 后台批次结束之后容量恢复，下一批可以照常进行。
	block.Store(false)
	close(release)
	if code := <-done; code != http.StatusOK {
		t.Fatalf("第一个后台批次应以 200 结束，得到 %d", code)
	}
	resp = env.c.Do(http.MethodPost, "/v1/llm/embeddings", token,
		bytes.NewReader(embedBody), workloadHeaders("batch"))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("后台批次结束之后应恢复容量，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()
}
