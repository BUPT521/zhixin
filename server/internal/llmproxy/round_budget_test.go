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

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// roundBudgetHeaders 是客户端带本轮剩余预算时的请求头；单位毫秒，与
// api/openapi.yaml 里 /v1/llm/responses 的 X-Zhixin-Round-Budget-Ms 一致。
func roundBudgetHeaders(ms int) map[string]string {
	return map[string]string{
		"Content-Type":             "application/json",
		"X-Zhixin-Round-Budget-Ms": fmt.Sprint(ms),
	}
}

func chatBody(stream bool) []byte {
	body := []byte(`{"model":"m","input":[{"type":"message","role":"user","content":"hi"}]`)
	if stream {
		body = append(body, `,"stream":true`...)
	}
	return append(body, '}')
}

// TestRoundDeadlineClampsToConfiguredMax 核对客户端给出的本轮剩余预算被换成本地
// 截止时间：没带时不设这一层期限，给得再大也按 RoundBudgetMax 截断，给 0 表示
// 这一轮已经用完。
func TestRoundDeadlineClampsToConfiguredMax(t *testing.T) {
	cfg := baseConfig()
	cfg.RoundBudgetMax = 5 * time.Second
	env := newTestServer(t, cfg, nil)
	p := env.proxy

	if deadline := p.roundDeadline(nil); !deadline.IsZero() {
		t.Fatalf("没有预算头时不应设截止时间，得到 %v", deadline)
	}

	long := int64(60000)
	if left := time.Until(p.roundDeadline(&long)); left > 5*time.Second+200*time.Millisecond {
		t.Fatalf("超过本机上限的值应截断到 5s，得到 %v", left)
	}

	short := int64(1000)
	if left := time.Until(p.roundDeadline(&short)); left > time.Second+200*time.Millisecond {
		t.Fatalf("本机上限以内的值应原样使用，得到 %v", left)
	}

	zero := int64(0)
	if deadline := p.roundDeadline(&zero); deadline.After(p.now()) {
		t.Fatalf("值为 0 时截止时间应当是现在，得到 %v", deadline)
	}
}

// TestStreamAttemptSwitchesBeforeFirstOutput 核对一条候选超过首字时限时换下一条：
// 客户端只看到备用来源的正文，慢的来源按失败记录一次尝试，没有冷却整个来源。
func TestStreamAttemptSwitchesBeforeFirstOutput(t *testing.T) {
	var slowHits, fastHits atomic.Int64
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		slowHits.Add(1)
		// 首字之前一直不写正文；到点之后由代理换路，这里只等一个上限，避免用例
		// 结束时服务端还在等连接。
		select {
		case <-r.Context().Done():
		case <-time.After(300 * time.Millisecond):
		}
	}))
	defer slow.Close()
	fast := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fastHits.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"备\"}\n\n")
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"total_tokens\":5}}}\n\n")
	}))
	defer fast.Close()

	cfg := baseConfig()
	cfg.FirstOutputTimeout = 100 * time.Millisecond
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "slow", slow.URL, "k1")
		putProvider(t, c, box, "fast", fast.URL, "k2")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "slow", UpstreamModel: "a", Priority: 1},
			{ProviderID: "fast", UpstreamModel: "b", Priority: 2},
		}})
	})
	usage := NewMemoryUsage()
	env.proxy.SetUsageStore(usage)
	token := signIn(t, env.authSvc, "switch@b.cn")

	start := time.Now()
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "备") {
		t.Fatalf("应换到备用来源并转发它的正文，得到 %d %q", resp.StatusCode, body)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("首字时限之后应立即换路，实际用了 %v", elapsed)
	}
	if slowHits.Load() != 1 || fastHits.Load() != 1 {
		t.Fatalf("每个来源应各尝试一次，得到 slow=%d fast=%d", slowHits.Load(), fastHits.Load())
	}

	rows, err := usage.RouteUsage(t.Context(), env.proxy.day(), env.proxy.day())
	if err != nil || len(rows) != 2 {
		t.Fatalf("应有两条尝试记录，得到 %+v, %v", rows, err)
	}
	for _, row := range rows {
		switch row.ProviderID {
		case "slow":
			if row.FirstAttempts != 1 || row.Successes != 0 {
				t.Fatalf("首发尝试应记为失败，得到 %+v", row)
			}
		case "fast":
			if row.FailoverAttempts != 1 || row.Successes != 1 {
				t.Fatalf("备用尝试应记为故障切换并成功，得到 %+v", row)
			}
		}
	}
	if views := env.proxy.router.health.modelViews(mustModel(t, env)); views[0].phase() != healthReady ||
		views[1].phase() != healthReady {
		t.Fatalf("一次首字超时不应让来源进入冷却，得到 %+v", views)
	}
}

// TestRoundBudgetExpiryReturnsGatewayTimeout 核对本轮预算在首个有效输出之前用完
// 时服务端明确结束这一轮：回 504 upstream_failed，而不是让请求一直挂着。
func TestRoundBudgetExpiryReturnsGatewayTimeout(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(400 * time.Millisecond):
		}
	}))
	defer upstream.Close()

	cfg := baseConfig()
	cfg.FirstOutputTimeout = 2 * time.Second
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "slow", upstream.URL, "k")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{{ProviderID: "slow", UpstreamModel: "a"}}})
	})
	token := signIn(t, env.authSvc, "budget@b.cn")

	start := time.Now()
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(80))
	if resp.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("预算用完应回 504，得到 %d", resp.StatusCode)
	}
	problem := testutil.ReadProblem(t, resp)
	if problem.Code != string(httpx.CodeUpstreamFailed) {
		t.Fatalf("预算用完的 code 应是 upstream_failed，得到 %+v", problem)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("预算用完应立即结束这一轮，实际用了 %v", elapsed)
	}
}

// TestNonStreamHonoursRoundBudget 核对非流式请求也按本轮预算结束，不再向来源发
// 请求：整段回答与流式共用同一条预算。
func TestNonStreamHonoursRoundBudget(t *testing.T) {
	var hits atomic.Int64
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[]}`)
	}))
	defer upstream.Close()

	cfg := baseConfig()
	cfg.StreamTotalTimeout = 30 * time.Second
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "up", upstream.URL, "k")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "a"}}})
	})
	token := signIn(t, env.authSvc, "plain@b.cn")

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(false)), roundBudgetHeaders(0))
	if resp.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("预算为 0 应回 504，得到 %d", resp.StatusCode)
	}
	if hits.Load() != 0 {
		t.Fatalf("预算用完时不应向来源发请求，实际发了 %d 次", hits.Load())
	}
}

// mustModel 取测试快照里唯一的模型。
func mustModel(t *testing.T, env *testEnv) *liveModel {
	t.Helper()
	m, ok := env.proxy.router.current().model("m")
	if !ok {
		t.Fatal("测试模型没有进快照")
	}
	return m
}
