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
// 没有输入量时不单列命中量，缺明细时按没有命中处理。
func TestUsageInputDetails(t *testing.T) {
	cases := []struct {
		name         string
		body         string
		input, cache int64
	}{
		{
			name:  "命中",
			body:  `{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":60},"output_tokens":10,"total_tokens":110}}`,
			input: 100, cache: 60,
		},
		{
			name:  "没有明细",
			body:  `{"usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}`,
			input: 100, cache: 0,
		},
		{
			name:  "命中量超过输入量",
			body:  `{"usage":{"input_tokens":40,"input_tokens_details":{"cached_tokens":90},"output_tokens":5}}`,
			input: 40, cache: 40,
		},
		{
			name: "没有输入量",
			body: `{"usage":{"output_tokens":5,"input_tokens_details":{"cached_tokens":12}}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			used := parseUsage([]byte(tc.body), KindChat)
			if used.Input != tc.input || used.Cached != tc.cache {
				t.Fatalf("input/cached = %d/%d, want %d/%d", used.Input, used.Cached, tc.input, tc.cache)
			}
		})
	}

	completion, amount := streamData([]byte(`{"type":"response.completed","response":{"usage":{"input_tokens":80,"input_tokens_details":{"cached_tokens":50},"output_tokens":20,"total_tokens":100}}}`))
	if completion != responseCompleted || amount.Total() != 100 || amount.Input != 80 || amount.Cached != 50 {
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
	want := map[string][2]int64{"plain": {120, 90}, "stream": {200, 150}}
	for _, row := range rows {
		expected, ok := want[row.ProviderID]
		if !ok {
			t.Fatalf("意外的来源 %q", row.ProviderID)
		}
		if row.InputTokens != expected[0] || row.CachedTokens != expected[1] {
			t.Fatalf("%s 的输入与命中量不对：%+v", row.ProviderID, row.UsageCounts)
		}
	}
}
