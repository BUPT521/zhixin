package llmproxy

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// TestHandlerDoesNotBillSourceRejections 核对来源明确拒绝（非 2xx）时结算记
// 0：请求没有产生回答，也没有产生上游计费，预留全部退回，不再按预留量扣。
func TestHandlerDoesNotBillSourceRejections(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprint(w, `{"error":{"message":"bad gateway"}}`)
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "only", upstream.URL, "sk")
		putModel(t, c, ModelRecord{Name: "zhixin-chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "only", UpstreamModel: "m"},
		}})
	})
	token := signIn(t, env.authSvc, "rejected@b.cn")
	chat := map[string]any{"model": "zhixin-chat", "input": []any{
		map[string]any{"type": "message", "role": "user", "content": "hi"},
	}}

	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusBadGateway {
		t.Fatalf("上游 502 应回 502，得到 %d", code)
	}
	var quota struct {
		Used int64 `json:"used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &quota)
	if quota.Used != 0 {
		t.Fatalf("来源拒绝不应扣额度，得到 %d", quota.Used)
	}
}

// TestHandlerBillsForwardedOutputWhenStreamBreaks 核对流式回答中断、没有拿到
// usage 时按输入估算与已经转出的输出结算，而不是按预留量扣：输入“hi”估 49，
// 输出“你好”估 2，计费量为 57。
func TestHandlerBillsForwardedOutputWhenStreamBreaks(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\n\n")
		w.(http.Flusher).Flush()
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "only", upstream.URL, "sk")
		putModel(t, c, ModelRecord{Name: "zhixin-chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "only", UpstreamModel: "m"},
		}})
	})
	token := signIn(t, env.authSvc, "broken@b.cn")
	chat := map[string]any{
		"model": "zhixin-chat", "stream": true,
		"input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}},
	}

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(mustJSON(t, chat)), nil)
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "你好") {
		t.Fatalf("中断前的内容应照常转发：%d %s", resp.StatusCode, body)
	}
	var quota struct {
		Used int64 `json:"used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &quota)
	if quota.Used != 57 {
		t.Fatalf("应按输入 49 加输出 2 结算为 57，得到 %d", quota.Used)
	}
}

// TestHandlerBillsResponseEstimateWhenUsageMissing 核对来源返回 2xx 却没有
// usage 时按整段响应的输出估算结算：输入“hi”估 49，输出“你好啊”估 3，
// 计费量为 61。
func TestHandlerBillsResponseEstimateWhenUsageMissing(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"r","object":"response","output":[
			{"type":"message","content":[{"type":"output_text","text":"你好啊"}]}
		]}`)
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "only", upstream.URL, "sk")
		putModel(t, c, ModelRecord{Name: "zhixin-chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "only", UpstreamModel: "m"},
		}})
	})
	token := signIn(t, env.authSvc, "nousage@b.cn")
	chat := map[string]any{"model": "zhixin-chat", "input": []any{
		map[string]any{"type": "message", "role": "user", "content": "hi"},
	}}

	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusOK {
		t.Fatalf("没有 usage 的响应仍应转发，得到 %d", code)
	}
	var quota struct {
		Used int64 `json:"used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &quota)
	if quota.Used != 61 {
		t.Fatalf("应按输入 49 加输出 3 结算为 61，得到 %d", quota.Used)
	}
}

// TestHandlerReservesImagesByCountNotBytes 核对预留按图片张数而不是 base64
// 字节数估算：700 KB 的内联图片在 30000 的额度下仍能放行，按字节估会直接拒绝。
func TestHandlerReservesImagesByCountNotBytes(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":10}}`)
	}))
	defer upstream.Close()

	cfg := baseConfig()
	cfg.DailyTokens = 30000
	cfg.MaxRequestBytes = 2 << 20
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "only", upstream.URL, "sk")
		putModel(t, c, ModelRecord{Name: "zhixin-chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "only", UpstreamModel: "m", SupportsImages: true},
		}})
	})
	token := signIn(t, env.authSvc, "image@b.cn")
	chat := map[string]any{"model": "zhixin-chat", "input": []any{
		map[string]any{"type": "message", "role": "user", "content": []any{
			map[string]any{"type": "input_text", "text": "看图"},
			map[string]any{
				"type":      "input_image",
				"image_url": "data:image/jpeg;base64," + strings.Repeat("A", 700_000),
			},
		}},
	}}

	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusOK {
		t.Fatalf("图片按张数估算后应放行，得到 %d", code)
	}
	var quota struct {
		Used int64 `json:"used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &quota)
	if quota.Used != 10 {
		t.Fatalf("应按来源报告的 10 结算，得到 %d", quota.Used)
	}
}

// TestMemoryQuotaInstanceCountsFreePortionOnly 核对实例账本只累计免费额度内的
// 部分：结算超出免费额度的用量由积分承担，不再占用实例预算。
func TestMemoryQuotaInstanceCountsFreePortionOnly(t *testing.T) {
	ctx := context.Background()
	q := NewMemoryQuota()
	q.SetQuotaLimits(100, 200, 1000)
	const day = "2026-11-18"

	if got, err := q.Reserve(ctx, "u1", day, KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("第一次预留应为 100，得到 %d %v", got, err)
	}
	if err := q.Settle(ctx, "u1", day, KindChat, "", 100, 250, Usage{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if used, _ := q.Used(ctx, "u1", day, KindChat); used != 250 {
		t.Fatalf("账号用量应为 250，得到 %d", used)
	}
	if used, _ := q.InstanceUsed(ctx, day); used != 100 {
		t.Fatalf("实例账本只应记免费额度内的 100，得到 %d", used)
	}
}
