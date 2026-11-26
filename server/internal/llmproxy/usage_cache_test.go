package llmproxy

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// TestUsageInputDetails 核对输入量与缓存命中量的读取：命中量不超过输入量，
// 没有输入量时不单列命中量，来源报了 0 与来源没有这个字段要分得开。
func TestUsageInputDetails(t *testing.T) {
	cases := []struct {
		name         string
		body         string
		input, cache int64
		reported     bool
	}{
		{
			name:  "命中",
			body:  `{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":60},"output_tokens":10,"total_tokens":110}}`,
			input: 100, cache: 60, reported: true,
		},
		{
			name:  "报了但没有命中",
			body:  `{"usage":{"input_tokens":50,"input_tokens_details":{"cached_tokens":0},"output_tokens":5}}`,
			input: 50, cache: 0, reported: true,
		},
		{
			name:  "没有明细",
			body:  `{"usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}`,
			input: 100, cache: 0,
		},
		{
			name:  "命中量超过输入量",
			body:  `{"usage":{"input_tokens":40,"input_tokens_details":{"cached_tokens":90},"output_tokens":5}}`,
			input: 40, cache: 40, reported: true,
		},
		{
			name: "没有输入量",
			body: `{"usage":{"output_tokens":5,"input_tokens_details":{"cached_tokens":12}}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			used := parseUsage([]byte(tc.body), KindChat)
			if used.Input != tc.input || used.Cached != tc.cache || used.CachedReported != tc.reported {
				t.Fatalf("input/cached/reported = %d/%d/%t, want %d/%d/%t",
					used.Input, used.Cached, used.CachedReported, tc.input, tc.cache, tc.reported)
			}
		})
	}

	completion, amount := streamData([]byte(`{"type":"response.completed","response":{"usage":{"input_tokens":80,"input_tokens_details":{"cached_tokens":50},"output_tokens":20,"total_tokens":100}}}`))
	if completion != responseCompleted || amount.Total() != 100 || amount.Input != 80 || amount.Cached != 50 || !amount.CachedReported {
		t.Fatalf("流式用量解析不对：%v %+v", completion, amount)
	}
}

// TestBilledTokens 守住计费 token 的折算口径：未命中输入记 1、命中输入记 1/50、
// 输出记 4；来源没有报告输入拆分时退回按原始 token 记，不把未知的输入当成输出。
func TestBilledTokens(t *testing.T) {
	cases := []struct {
		name string
		used Usage
		kind Kind
		want int64
	}{
		{name: "全部未命中", used: Usage{Input: 1_000_000}, want: 1_000_000},
		{name: "全部命中", used: Usage{Input: 1_000_000, Cached: 1_000_000}, want: 20_000},
		{name: "一半命中", used: Usage{Input: 1_000_000, Cached: 500_000}, want: 510_000},
		{name: "输出按四倍", used: Usage{Input: 1_000_000, Output: 250_000}, want: 2_000_000},
		{name: "没有输入拆分时按原始计", used: Usage{Output: 900_000}, want: 900_000},
		{name: "嵌入按原始计", used: Usage{Input: 700_000}, kind: KindEmbedding, want: 700_000},
		{name: "命中量超过输入量时截断", used: Usage{Input: 100, Cached: 500}, want: 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.used.Billed(tc.kind); got != tc.want {
				t.Fatalf("Billed = %d, want %d", got, tc.want)
			}
		})
	}
	if got := (Usage{Input: 1_000, Output: 1_000}).reserve(KindChat); got != 5_000 {
		t.Fatalf("预留估算 = %d, want 5000", got)
	}
}

// TestRouteUsageRecordsCachedTokens 核对请求把输入量与缓存命中量记进路由用量，
// 流式与非流式都一样，供发布前后的缓存命中占比对照。
func TestRouteUsageRecordsCachedTokens(t *testing.T) {
	nonStream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":90},"output_tokens":11,"total_tokens":131}}`)
	}))
	defer nonStream.Close()
	stream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"好"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.completed","response":{"usage":{"input_tokens":200,"input_tokens_details":{"cached_tokens":150},"output_tokens":9,"total_tokens":209}}}`))
	}))
	defer stream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "plain", nonStream.URL, "k1")
		putProvider(t, c, box, "stream", stream.URL, "k2")
		putModel(t, c, ModelRecord{Name: "plain", Kind: KindChat, Routes: []Route{{ProviderID: "plain", UpstreamModel: "a"}}})
		putModel(t, c, ModelRecord{Name: "stream", Kind: KindChat, Routes: []Route{{ProviderID: "stream", UpstreamModel: "b"}}})
	})
	usage := NewMemoryUsage()
	env.proxy.SetUsageStore(usage)
	token := signIn(t, env.authSvc, "cache@b.cn")

	nonStreamBody := []byte(`{"model":"plain","input":[{"type":"message","role":"user","content":"hi"}]}`)
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(nonStreamBody), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("非流式请求应成功，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()

	streamBody := []byte(`{"model":"stream","stream":true,"input":[{"type":"message","role":"user","content":"hi"}]}`)
	resp = env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(streamBody), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("流式请求应成功，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()

	rows, err := usage.RouteUsage(t.Context(), env.proxy.day(), env.proxy.day())
	if err != nil || len(rows) != 2 {
		t.Fatalf("应有两条路由的用量，得到 %+v, %v", rows, err)
	}
	type want struct{ input, cached, reports int64 }
	expected := map[string]want{"plain": {120, 90, 1}, "stream": {200, 150, 1}}
	for _, row := range rows {
		w, ok := expected[row.ProviderID]
		if !ok {
			t.Fatalf("意外的来源 %q", row.ProviderID)
		}
		if row.InputTokens != w.input || row.CachedTokens != w.cached ||
			row.FirstInputTokens != w.input || row.FirstCachedTokens != w.cached ||
			row.FirstInputReports != w.reports || row.FirstCachedReports != w.reports {
			t.Fatalf("%s 的输入与命中量不对：%+v", row.ProviderID, row.UsageCounts)
		}
		if row.FailoverInputReports != 0 || row.FailoverCachedReports != 0 {
			t.Fatalf("%s 没有换路，换路栏应为空：%+v", row.ProviderID, row.UsageCounts)
		}
	}
}

// TestRouteUsageSeparatesUnreportedCache 核对来源给了输入量却没有给 cached_tokens
// 时，这次尝试只记一条输入上报、不记缓存上报：命中率按 0 算，缺报在后台单独显示。
func TestRouteUsageSeparatesUnreportedCache(t *testing.T) {
	quiet := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"input_tokens":300,"output_tokens":12,"total_tokens":312}}`)
	}))
	defer quiet.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "quiet", quiet.URL, "k3")
		putModel(t, c, ModelRecord{Name: "quiet", Kind: KindChat, Routes: []Route{{ProviderID: "quiet", UpstreamModel: "c"}}})
	})
	usage := NewMemoryUsage()
	env.proxy.SetUsageStore(usage)
	token := signIn(t, env.authSvc, "quiet@b.cn")

	body := []byte(`{"model":"quiet","input":[{"type":"message","role":"user","content":"hi"}]}`)
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(body), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("请求应成功，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()

	rows, err := usage.RouteUsage(t.Context(), env.proxy.day(), env.proxy.day())
	if err != nil || len(rows) != 1 {
		t.Fatalf("应有一条路由的用量，得到 %+v, %v", rows, err)
	}
	row := rows[0].UsageCounts
	if row.FirstInputReports != 1 || row.FirstCachedReports != 0 {
		t.Fatalf("缺报应只记输入上报：%+v", row)
	}
	if row.InputTokens != 300 || row.CachedTokens != 0 || row.FirstInputTokens != 300 {
		t.Fatalf("输入量与命中量不对：%+v", row)
	}
}

// TestRouteUsageSplitsCacheByAttemptOrder 核对换路之后接手的尝试记在换路栏：首次
// 尝试被来源的 503 挡回来、没有拿到用量，因此不进缓存统计，接手的那次按自己的
// 用量记，两栏之和仍是合计。
func TestRouteUsageSplitsCacheByAttemptOrder(t *testing.T) {
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprint(w, `{"error":{"message":"busy"}}`)
	}))
	defer down.Close()
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"input_tokens":500,"input_tokens_details":{"cached_tokens":400},"output_tokens":20,"total_tokens":520}}`)
	}))
	defer up.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "down", down.URL, "k4")
		putProvider(t, c, box, "up", up.URL, "k5")
		putModel(t, c, ModelRecord{Name: "chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "down", UpstreamModel: "a", Priority: 0},
			{ProviderID: "up", UpstreamModel: "b", Priority: 1},
		}})
	})
	usage := NewMemoryUsage()
	env.proxy.SetUsageStore(usage)
	token := signIn(t, env.authSvc, "failover-cache@b.cn")

	body := []byte(`{"model":"chat","input":[{"type":"message","role":"user","content":"hi"}]}`)
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(body), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("备用来源应接住这次请求，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()

	rows, err := usage.RouteUsage(t.Context(), env.proxy.day(), env.proxy.day())
	if err != nil {
		t.Fatalf("读路由用量：%v", err)
	}
	var total UsageCounts
	for _, row := range rows {
		total.add(row.UsageCounts)
	}
	if total.FirstInputReports != 0 || total.FirstCachedReports != 0 {
		t.Fatalf("被挡回来的首次尝试没有用量，不应进入缓存统计：%+v", total)
	}
	if total.FailoverInputReports != 1 || total.FailoverCachedReports != 1 ||
		total.FailoverInputTokens != 500 || total.FailoverCachedTokens != 400 {
		t.Fatalf("换路栏不对：%+v", total)
	}
	if total.InputTokens != 500 || total.CachedTokens != 400 {
		t.Fatalf("合计应等于换路栏：%+v", total)
	}
}
