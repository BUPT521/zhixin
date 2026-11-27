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

func TestRoutingSessionKeyFallsBackToFirstUserMessage(t *testing.T) {
	initial := []byte(`[{"role":"developer","content":"规则"},{"role":"user","content":[{"type":"input_text","text":"第一问"}]}]`)
	followup := []byte(`[{"role":"developer","content":"更新后的规则"},{"role":"user","content":[ { "type":"input_text", "text":"第一问" } ]},{"role":"assistant","content":"上次回答"},{"role":"user","content":"追问"}]`)
	key := routingSessionKey("u1", nil, initial)
	if key == "" || routingSessionKey("u1", nil, followup) != key {
		t.Fatal("追加消息、更新开发者指令或改变 JSON 空白时应复用首条用户消息的调度键")
	}
	blank, long := "  ", strings.Repeat("x", maxSessionIDBytes+1)
	for _, id := range []*string{&blank, &long} {
		if routingSessionKey("u1", id, initial) != key {
			t.Fatal("无效标识应按首条用户消息调度")
		}
	}
	explicit := "discussion-7"
	if routingSessionKey("u1", &explicit, initial) != sessionKey("u1", &explicit) {
		t.Fatal("显式讨论标识应优先")
	}
	if routingSessionKey("u2", nil, initial) == key {
		t.Fatal("不同账号的相同消息不应共用调度键")
	}
	if other := routingSessionKey("u1", nil, []byte(`[{"role":"user","content":"另一条讨论"}]`)); other == "" || other == key {
		t.Fatal("首条消息不同应得到不同的键")
	}
	for _, input := range []string{
		`[]`,
		`[{"role":"developer","content":"只有指令"}]`,
		`[{"role":"user","content":"   "}]`,
		`[{"role":"user","content":[]}]`,
	} {
		if routingSessionKey("u1", nil, []byte(input)) != "" {
			t.Fatalf("没有可用首条用户消息时应保持随机路由：%s", input)
		}
	}
}

// TestSessionHeaderKeepsOneRoute 核对显式标识和首条用户消息都能稳定选择来源。
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
	var shuffled atomic.Int64
	env.proxy.router.shuffle = func(routes []liveRoute) {
		shuffled.Add(1)
		weightedShuffle(routes)
	}
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

	beforeA, beforeB := hitsA.Load(), hitsB.Load()
	for _, requestBody := range [][]byte{
		body,
		[]byte(`{"model":"m","instructions":"本轮新指令","input":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"},{"role":"user","content":"追问"}]}`),
	} {
		resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
			bytes.NewReader(requestBody), roundBudgetHeaders(5000))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("不带标识的请求应成功，得到 %d", resp.StatusCode)
		}
		resp.Body.Close()
	}
	afterA, afterB := hitsA.Load()-beforeA, hitsB.Load()-beforeB
	if shuffled.Load() != 0 || afterA+afterB != 2 || (afterA != 0 && afterB != 0) {
		t.Fatalf("带同一首条消息的无标识请求应复用首选来源，得到 a=%d b=%d，随机次数 %d", afterA, afterB, shuffled.Load())
	}

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		strings.NewReader(`{"model":"m","instructions":"仅有指令","input":[]}`), roundBudgetHeaders(5000))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || shuffled.Load() != 1 {
		t.Fatalf("没有首条用户消息时应按原有方式随机，得到状态 %d，随机次数 %d", resp.StatusCode, shuffled.Load())
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

// TestSessionSticksToTakeoverRoute 核对首次尝试失败、备用来源接住之后，同一条讨论
// 在粘滞期内继续从备用来源开始，不让恢复的主来源马上回切；粘滞期过后回到按会话
// 顺序分配，别的讨论不受影响。
func TestSessionSticksToTakeoverRoute(t *testing.T) {
	var failA atomic.Bool
	failA.Store(true)
	var hitsA, hitsB atomic.Int64
	sourceA := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hitsA.Add(1)
		w.Header().Set("Content-Type", "application/json")
		if failA.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprint(w, `{"error":{"message":"busy"}}`)
			return
		}
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"total_tokens":5}}`)
	}))
	defer sourceA.Close()
	sourceB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hitsB.Add(1)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"total_tokens":5}}`)
	}))
	defer sourceB.Close()

	cfg := baseConfig()
	cfg.DailyTokens = 10_000_000
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "a", sourceA.URL, "k1")
		putProvider(t, c, box, "b", sourceB.URL, "k2")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "a", UpstreamModel: "a", Priority: 0},
			{ProviderID: "b", UpstreamModel: "b", Priority: 1},
		}})
	})
	clock := time.Now()
	env.proxy.router.now = func() time.Time { return clock }
	token := signIn(t, env.authSvc, "sticky@b.cn")
	body := chatBody(false)

	ask := func(session string) {
		t.Helper()
		resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
			bytes.NewReader(body), sessionHeaders(session))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("请求应成功，得到 %d", resp.StatusCode)
		}
		resp.Body.Close()
	}

	// 第一次：主来源 503，备用接住。
	ask("discussion-sticky")
	if hitsA.Load() != 1 || hitsB.Load() != 1 {
		t.Fatalf("首次失败后应由备用接住：a=%d b=%d", hitsA.Load(), hitsB.Load())
	}

	// 主来源恢复：粘滞期内仍走接手的备用来源。
	failA.Store(false)
	ask("discussion-sticky")
	if hitsA.Load() != 1 || hitsB.Load() != 2 {
		t.Fatalf("粘滞期内应继续走备用：a=%d b=%d", hitsA.Load(), hitsB.Load())
	}

	// 另一条讨论没有接手记录，仍按优先级走主来源。
	ask("discussion-other")
	if hitsA.Load() != 2 || hitsB.Load() != 2 {
		t.Fatalf("别的讨论不应受粘滞影响：a=%d b=%d", hitsA.Load(), hitsB.Load())
	}

	// 粘滞期过后回到主来源。
	clock = clock.Add(stickyAfterTakeover + time.Minute)
	ask("discussion-sticky")
	if hitsA.Load() != 3 || hitsB.Load() != 2 {
		t.Fatalf("粘滞期过后应回到主来源：a=%d b=%d", hitsA.Load(), hitsB.Load())
	}
}

// TestStickyRoutesRespectHealthAndCapabilities 核对接手的路由不可用或缺少本次需要
// 的能力时，粘滞不让它重新进入候选。
func TestStickyRoutesRespectHealthAndCapabilities(t *testing.T) {
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "a", "https://a.example", "k")
		putProvider(t, c, box, "b", "https://b.example", "k")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "a", UpstreamModel: "a", Priority: 0, SupportsTools: true},
			{ProviderID: "b", UpstreamModel: "b", Priority: 1, SupportsTools: false},
		}})
	})
	router := env.proxy.router
	m := mustModel(t, env)
	router.rememberTakeover("s", routeHealthKey(m, m.Live[1]))

	if got := routeIDs(router.candidates(m, "s", capabilities{})); got != "b,a" {
		t.Fatalf("接手的路由应排在最前：%s", got)
	}
	if got := routeIDs(router.candidates(m, "s", capabilities{tools: true})); got != "a" {
		t.Fatalf("缺少函数调用能力的路由不应因粘滞重新进入候选：%s", got)
	}

	other := *m
	other.Name = "other-model"
	if got := routeIDs(router.candidates(&other, "s", capabilities{})); got != "a,b" {
		t.Fatalf("同一讨论改用另一模型时应按该模型的路由配置选择：%s", got)
	}
}
