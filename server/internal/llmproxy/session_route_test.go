package llmproxy

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// sessionHeaders 是带讨论标识的对话请求头；会话标识与轮次预算一起送。
func sessionHeaders(session string) map[string]string {
	return map[string]string{
		"Content-Type":             "application/json",
		"X-Zhixin-Round-Budget-Ms": "5000",
		"X-Zhixin-Session-Id":      session,
	}
}

// TestSessionOrderIsStable 核对同一会话在同一组候选上每次得到同一个顺序，不同
// 会话按各自的顺序分开，不会因为每次请求重新随机而换到别的来源。
func TestSessionOrderIsStable(t *testing.T) {
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		for _, id := range []string{"a", "b", "c"} {
			putProvider(t, c, box, id, "https://"+id+".example", "k")
		}
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "a", UpstreamModel: "a", Priority: 1},
			{ProviderID: "b", UpstreamModel: "b", Priority: 1},
			{ProviderID: "c", UpstreamModel: "c", Priority: 1},
		}})
	})
	m := mustModel(t, env)
	router := env.proxy.router

	first := ""
	seen := map[string]bool{}
	for _, session := range []string{"s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8"} {
		order := routeIDs(router.candidates(m, session, capabilities{}))
		if order != routeIDs(router.candidates(m, session, capabilities{})) {
			t.Fatalf("同一会话两次得到不同顺序：%s", order)
		}
		if order == "" {
			t.Fatal("会话路由不应为空")
		}
		seen[order[:1]] = true
		if session == "s1" {
			first = order
		}
	}
	if first == "" || len(seen) < 2 {
		t.Fatalf("不同会话应分到不同的首选来源，得到首字集合 %v", seen)
	}
}

// TestSessionOrderFollowsWeights 核对会话顺序仍按权重分配：权重 9:1 时约九成
// 会话落到权重大的那条路由，其余会话落到另一条。
func TestSessionOrderFollowsWeights(t *testing.T) {
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "a", "https://a.example", "k")
		putProvider(t, c, box, "b", "https://b.example", "k")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "a", UpstreamModel: "a", Priority: 1, Weight: 9},
			{ProviderID: "b", UpstreamModel: "b", Priority: 1, Weight: 1},
		}})
	})
	m := mustModel(t, env)

	const sessions = 4000
	heavy := 0
	for i := range sessions {
		order := routeIDs(env.proxy.router.candidates(m, fmt.Sprintf("session-%d", i), capabilities{}))
		if strings.HasPrefix(order, "a") {
			heavy++
		}
	}
	if share := float64(heavy) / sessions; share < 0.86 || share > 0.94 {
		t.Fatalf("权重 9:1 时约有 90%% 的会话落到 a，实际 %.3f", share)
	}
}

// TestSessionKeyScopesAccount 核对调度键只由账号与讨论标识决定：同一账号的同一
// 讨论稳定，换账号、空白或超长标识都不参与会话分配。
func TestSessionKeyScopesAccount(t *testing.T) {
	id := "discussion-1"
	if sessionKey("u1", &id) != sessionKey("u1", &id) {
		t.Fatal("同一账号与同一讨论应得到同一个键")
	}
	if sessionKey("u1", &id) == sessionKey("u2", &id) {
		t.Fatal("不同账号的同一讨论标识不应共用分配")
	}
	if sessionKey("u1", nil) != "" {
		t.Fatal("没有标识时应返回空键")
	}
	blank := "  "
	if sessionKey("u1", &blank) != "" {
		t.Fatal("空白标识应按没有处理")
	}
	long := strings.Repeat("x", maxSessionIDBytes+1)
	if sessionKey("u1", &long) != "" {
		t.Fatal("超长标识应按没有处理")
	}
}

// TestSessionHeaderKeepsOneRoute 核对带讨论标识的几次请求都落到同一条来源并
// 只记这一个来源的用量；不带标识时仍按权重分散到两条来源。
func TestSessionHeaderKeepsOneRoute(t *testing.T) {
	var hitsA, hitsB atomic.Int64
	reply := func(hits *atomic.Int64) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"total_tokens":5}}`)
		}
	}
	upstreamA := httptest.NewServer(reply(&hitsA))
	defer upstreamA.Close()
	upstreamB := httptest.NewServer(reply(&hitsB))
	defer upstreamB.Close()

	cfg := baseConfig()
	cfg.DailyTokens = 10_000_000
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "a", upstreamA.URL, "k1")
		putProvider(t, c, box, "b", upstreamB.URL, "k2")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "a", UpstreamModel: "a", Priority: 1},
			{ProviderID: "b", UpstreamModel: "b", Priority: 1},
		}})
	})
	usage := NewMemoryUsage()
	env.proxy.SetUsageStore(usage)
	// 测试装配默认关掉随机头部次序，这里恢复按权重随机，才看得到不带标识时的
	// 分散效果。
	env.proxy.router.shuffle = weightedShuffle
	token := signIn(t, env.authSvc, "session@b.cn")
	body := chatBody(false)

	for range 4 {
		resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
			bytes.NewReader(body), sessionHeaders("discussion-7"))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("同一会话的请求应成功，得到 %d", resp.StatusCode)
		}
		resp.Body.Close()
	}
	rows, err := usage.RouteUsage(t.Context(), env.proxy.day(), env.proxy.day())
	if err != nil || len(rows) != 1 {
		t.Fatalf("同一会话的四次请求应只落到一条来源，得到 %+v, %v", rows, err)
	}
	if total := hitsA.Load() + hitsB.Load(); total != 4 {
		t.Fatalf("应共发出 4 次上游调用，得到 %d", total)
	}

	// 不带标识时按权重重新随机：二十次请求里两条来源都应当被用到。
	for range 20 {
		resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
			bytes.NewReader(body), roundBudgetHeaders(5000))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("不带标识的请求应成功，得到 %d", resp.StatusCode)
		}
		resp.Body.Close()
	}
	if hitsA.Load() == 4 || hitsB.Load() == 0 {
		t.Fatalf("不带标识时应分散到两条来源，得到 a=%d b=%d", hitsA.Load(), hitsB.Load())
	}
}

// routeIDs 把候选按顺序写成来源标识，便于比较。
func routeIDs(routes []liveRoute) string {
	parts := make([]string, len(routes))
	for i, rt := range routes {
		parts[i] = rt.Provider.ID
	}
	return strings.Join(parts, ",")
}
