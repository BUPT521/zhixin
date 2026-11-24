package llmproxy

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// imageChatBody 是带一张图片的对话请求，形状与客户端的 Responses 请求一致。
func imageChatBody(model string) []byte {
	return []byte(`{"model":"` + model + `","input":[{"type":"message","role":"user","content":[` +
		`{"type":"input_text","text":"看这张图"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}]}`)
}

// toolsChatBody 是声明了 tools 的对话请求。
func toolsChatBody(model string) []byte {
	return []byte(`{"model":"` + model + `","input":[{"type":"message","role":"user","content":"hi"}],` +
		`"tools":[{"type":"function","name":"next_steps","parameters":{"type":"object","properties":{}}}]}`)
}

// TestRequiredCapabilities 核对从请求体判断能力：只有 tools 数组非空才算要函数
// 调用，只有 content 数组里出现 input_image 才算要读图片，字符串内容不误判。
func TestRequiredCapabilities(t *testing.T) {
	cases := []struct {
		name string
		body string
		want capabilities
	}{
		{"纯文本", `{"input":[{"type":"message","role":"user","content":"看这张图"}]}`, capabilities{}},
		{
			name: "图片",
			body: `{"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"x"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]}]}`,
			want: capabilities{images: true},
		},
		{
			name: "工具",
			body: `{"input":[{"type":"message","role":"user","content":"hi"}],"tools":[{"type":"function","name":"a"}]}`,
			want: capabilities{tools: true},
		},
		{
			name: "空工具列表不算",
			body: `{"input":[],"tools":[]}`,
		},
		{
			name: "工具结果的字符串内容不误判",
			body: `{"input":[{"type":"function_call_output","call_id":"c","output":"input_image 只是文字"}]}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal([]byte(tc.body), &fields); err != nil {
				t.Fatal(err)
			}
			if got := requiredCapabilities(fields); got != tc.want {
				t.Fatalf("requiredCapabilities = %+v, want %+v", got, tc.want)
			}
		})
	}
}

// TestCandidatesFilterByCapability 核对需要工具或图片时，只留下标了对应能力的
// 路由；没有要求时候选不受影响。
func TestCandidatesFilterByCapability(t *testing.T) {
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "text", "https://text.example", "k1")
		putProvider(t, c, box, "vision", "https://vision.example", "k2")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "text", UpstreamModel: "a", Priority: 1, SupportsTools: true, SupportsImages: false},
			{ProviderID: "vision", UpstreamModel: "b", Priority: 2, SupportsTools: true, SupportsImages: true},
		}})
	})
	m := mustModel(t, env)
	router := env.proxy.router

	if got := routeIDs(router.candidates(m, "", capabilities{})); got != "text,vision" {
		t.Fatalf("没有能力要求时应保留全部候选，得到 %s", got)
	}
	if got := routeIDs(router.candidates(m, "", capabilities{images: true})); got != "vision" {
		t.Fatalf("要图片时应只剩支持图片的路由，得到 %s", got)
	}
	if got := routeIDs(router.candidates(m, "", capabilities{tools: true})); got != "text,vision" {
		t.Fatalf("两条路由都支持工具，得到 %s", got)
	}
}

// TestChatRequestSkipsIncapableRoutes 核对带图片的请求不发到不支持图片的路由，
// 没有具备所需能力的路由时在本地就说明缺哪一种能力。
func TestChatRequestSkipsIncapableRoutes(t *testing.T) {
	var textHits, visionHits atomic.Int64
	reply := func(hits *atomic.Int64) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"object":"response","status":"completed","output":[],"usage":{"total_tokens":5}}`)
		}
	}
	text := httptest.NewServer(reply(&textHits))
	defer text.Close()
	vision := httptest.NewServer(reply(&visionHits))
	defer vision.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "text", text.URL, "k1")
		putProvider(t, c, box, "vision", vision.URL, "k2")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "text", UpstreamModel: "a", Priority: 1, SupportsTools: true, SupportsImages: false},
			{ProviderID: "vision", UpstreamModel: "b", Priority: 2, SupportsTools: true, SupportsImages: true},
		}})
		putModel(t, c, ModelRecord{Name: "text-only", Kind: KindChat, Routes: []Route{
			{ProviderID: "text", UpstreamModel: "a", Priority: 1, SupportsTools: false, SupportsImages: false},
		}})
	})
	token := signIn(t, env.authSvc, "caps@b.cn")

	// 带图片：支持图片的是备用路由，也要跳过低优先级里不支持的那条。
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(imageChatBody("m")), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("带图片的请求应成功，得到 %d", resp.StatusCode)
	}
	resp.Body.Close()
	if textHits.Load() != 0 || visionHits.Load() != 1 {
		t.Fatalf("带图片的请求应只走支持图片的路由，得到 text=%d vision=%d", textHits.Load(), visionHits.Load())
	}

	// 纯文本与工具请求不受图片能力影响，仍然走主用的那条。
	for _, body := range [][]byte{chatBody(false), toolsChatBody("m")} {
		resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
			bytes.NewReader(body), roundBudgetHeaders(5000))
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("纯文本或工具请求应成功，得到 %d", resp.StatusCode)
		}
		resp.Body.Close()
	}
	if textHits.Load() != 2 {
		t.Fatalf("纯文本与工具请求应走主用路由，得到 %d", textHits.Load())
	}

	// 没有支持图片的路由时直接说明缺图片能力，不发出上游请求。
	resp = env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(imageChatBody("text-only")), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("没有支持图片的路由应回 502，得到 %d", resp.StatusCode)
	}
	problem := testutil.ReadProblem(t, resp)
	if !strings.Contains(problem.Detail, "image input") {
		t.Fatalf("应说明缺图片能力，得到 %+v", problem)
	}

	// 工具请求同理。
	resp = env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(toolsChatBody("text-only")), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("没有支持工具的路由应回 502，得到 %d", resp.StatusCode)
	}
	problem = testutil.ReadProblem(t, resp)
	if !strings.Contains(problem.Detail, "tool calls") {
		t.Fatalf("应说明缺工具能力，得到 %+v", problem)
	}
}
