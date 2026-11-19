package server

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
)

const testAdminToken = "admin-token-0123456789abcdef0123456789"

// fakeProvider 同时提供 /models、/chat/completions 与 /embeddings，记录收到的
// key 与模型名。
func fakeProvider(t *testing.T) (*httptest.Server, func() string) {
	t.Helper()
	var mu sync.Mutex
	var lastRequest string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		lastRequest = r.Method + " " + r.URL.Path + " " + r.Header.Get("Authorization")
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/models":
			fmt.Fprint(w, `{"object":"list","data":[{"id":"qwen-plus"},{"id":"text-embedding-v4"}]}`)
		case "/v1/chat/completions":
			fmt.Fprint(w, `{"choices":[{"message":{"content":"pong"}}],"usage":{"total_tokens":3}}`)
		case "/v1/embeddings":
			var body struct {
				Input []string `json:"input"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			var data []string
			for i := range body.Input {
				data = append(data, fmt.Sprintf(`{"index":%d,"embedding":[0.1,0.2,0.3]}`, i))
			}
			fmt.Fprintf(w, `{"data":[%s],"usage":{"prompt_tokens":4,"total_tokens":4}}`, strings.Join(data, ","))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, func() string {
		mu.Lock()
		defer mu.Unlock()
		return lastRequest
	}
}

func TestAdminDisabledWithoutToken(t *testing.T) {
	h := newHarness(t, nil)
	for _, path := range []string{"/admin", "/admin/", "/admin/app.js", "/admin/v1/providers", "/admin/v1/usage?days=invalid"} {
		resp := h.do("GET", path, testAdminToken, nil, nil)
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: 没有配置管理令牌时应 404，得到 %d", path, resp.StatusCode)
		}
	}
}

func TestAdminUsageIncludesFallbackAndExcludesProbes(t *testing.T) {
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, "<html>Service temporarily unavailable</html>")
	}))
	defer primary.Close()
	backup := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/embeddings" {
			var in struct{ Input []string }
			_ = json.NewDecoder(r.Body).Decode(&in)
			if len(in.Input) != 1 {
				t.Error("expected each embedding chunk to contain one input")
			}
			if len(in.Input) == 1 && in.Input[0] == "one" {
				fmt.Fprint(w, `{"data":[{"index":0,"embedding":[0.1]}],"usage":{"total_tokens":7}}`)
			} else {
				fmt.Fprint(w, `{"data":[{"index":0,"embedding":[0.2]}]}`)
			}
			return
		}
		var in struct{ Stream bool }
		_ = json.NewDecoder(r.Body).Decode(&in)
		if in.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":6}}\n\n")
			return
		}
		fmt.Fprint(w, `{"choices":[{"message":{"content":"fallback"}}],"usage":{"total_tokens":9}}`)
	}))
	defer backup.Close()
	h := newHarness(t, map[string]string{
		"ZHIXIN_ADMIN_TOKEN": testAdminToken, "ZHIXIN_LLM_REQUIRE_VERIFIED_EMAIL": "0",
		"ZHIXIN_TIMEZONE": "Asia/Shanghai",
	})
	admin := func(method, path string, in, out any, want int) {
		t.Helper()
		if code := h.json(method, path, testAdminToken, in, out); code != want {
			t.Fatalf("%s %s: got %d, want %d", method, path, code, want)
		}
	}
	var report api.AdminUsageReport
	admin("GET", "/admin/v1/usage", nil, &report, http.StatusOK)
	if len(report.Daily) != 7 || report.Timezone != "Asia/Shanghai" || len(report.Routes) != 0 {
		t.Fatalf("empty report: %+v", report)
	}
	admin("GET", "/admin/v1/usage?days=31", nil, nil, http.StatusBadRequest)
	admin("GET", "/admin/v1/usage?days=invalid", nil, nil, http.StatusBadRequest)
	user := h.signUp("route-stats@example.test")
	if code := h.json("GET", "/admin/v1/usage?days=invalid", user, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("invalid query with account token: %d", code)
	}
	for id, baseURL := range map[string]string{"primary": primary.URL, "backup": backup.URL} {
		admin("PUT", "/admin/v1/providers/"+id, map[string]string{"base_url": baseURL}, nil, http.StatusOK)
	}
	admin("PUT", "/admin/v1/models/chat-test", map[string]any{
		"kind": "chat", "routes": []map[string]any{
			{"provider_id": "primary", "upstream_model": "first"},
			{"provider_id": "backup", "upstream_model": "second", "priority": 1},
		},
	}, nil, http.StatusOK)
	admin("PUT", "/admin/v1/models/embed-test", map[string]any{
		"kind": "embedding", "routes": []map[string]any{{"provider_id": "backup", "upstream_model": "embed", "max_batch": 1}},
	}, nil, http.StatusOK)
	for _, call := range []struct {
		path string
		body map[string]any
	}{
		{"/v1/llm/chat/completions", map[string]any{"model": "chat-test", "messages": []any{}}},
		{"/v1/llm/embeddings", map[string]any{"model": "embed-test", "input": []string{"one", "two"}}},
	} {
		if code := h.json("POST", call.path, user, call.body, nil); code != http.StatusOK {
			t.Fatalf("%s: %d", call.path, code)
		}
	}
	stream := h.do("POST", "/v1/llm/chat/completions", user,
		strings.NewReader(`{"model":"chat-test","messages":[],"stream":true}`), map[string]string{"Content-Type": "application/json"})
	sse, err := io.ReadAll(stream.Body)
	stream.Body.Close()
	if err != nil || stream.StatusCode != http.StatusOK || !strings.Contains(string(sse), "finish_reason") {
		t.Fatalf("stream fallback: %d %q %v", stream.StatusCode, sse, err)
	}
	var probe api.AdminProbe
	admin("POST", "/admin/v1/models/chat-test/test", nil, &probe, http.StatusOK)
	if !probe.Ok || probe.ProviderId == nil || *probe.ProviderId != "backup" {
		t.Fatalf("probe did not use fallback: %+v", probe)
	}
	admin("GET", "/admin/v1/usage?days=1", nil, &report, http.StatusOK)
	if len(report.Daily) != 1 || len(report.Routes) != 3 {
		t.Fatalf("route usage: %+v", report)
	}
	day := report.Daily[0]
	if day.Chat.Attempts != 4 || day.Chat.Successes != 2 || day.Chat.EstimatedTokens <= 0 ||
		day.Chat.Tokens-day.Chat.EstimatedTokens != 15 || day.Embedding != (api.AdminUsageCounts{
		Attempts: 1, Successes: 1, Tokens: 10, EstimatedTokens: 3,
	}) {
		t.Fatalf("daily totals: %+v", day)
	}
	for _, route := range report.Routes {
		switch {
		case route.ProviderId == "primary" && (route.Usage.Successes != 0 || route.Usage.Attempts != 2 || route.Usage.EstimatedTokens != route.Usage.Tokens):
			t.Fatalf("primary: %+v", route)
		case route.UpstreamModel == "second" && route.Usage != (api.AdminUsageCounts{Attempts: 2, Successes: 2, Tokens: 15}):
			t.Fatalf("fallback: %+v", route)
		}
	}
	admin("PUT", "/admin/v1/providers/backup", map[string]any{"base_url": backup.URL, "enabled": false}, nil, http.StatusOK)
	var models api.AdminModelList
	admin("GET", "/admin/v1/models", nil, &models, http.StatusOK)
	for _, model := range models.Data {
		if model.Name == "embed-test" && (model.Available || model.Routes[0].State != api.AdminRouteStateProviderDisabled) {
			t.Fatalf("disabled provider shown as available: %+v", model)
		}
	}
}

func TestAdminTokenAndPage(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_ADMIN_TOKEN": testAdminToken,
		"ZHIXIN_ADMIN_RATE":  "0.001",
		"ZHIXIN_ADMIN_BURST": "2",
	})

	resp := h.do("GET", "/admin/", "", nil, nil)
	page, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(page), "模型后台") {
		t.Fatalf("页面不需要令牌即可打开：%d", resp.StatusCode)
	}
	if csp := resp.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "script-src 'self'") {
		t.Fatalf("页面应带 CSP：%q", csp)
	}
	if resp.Header.Get("Cache-Control") != "no-store" || resp.Header.Get("X-Frame-Options") != "DENY" {
		t.Fatalf("后台响应应禁止缓存与嵌入：%v", resp.Header)
	}

	// 账号的访问令牌不能当管理令牌用。
	user := h.signUp("admin-probe@b.cn")
	if code := h.json("GET", "/admin/v1/providers", user, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("账号令牌应被拒：%d", code)
	}
	if code := h.json("GET", "/admin/v1/providers", testAdminToken, nil, nil); code != http.StatusOK {
		t.Fatalf("管理令牌应通过：%d", code)
	}
	// 失败次数用完之后按来源地址限流（第一次失败已经用掉一个）。
	h.json("GET", "/admin/v1/providers", "wrong", nil, nil)
	resp = h.do("GET", "/admin/v1/providers", "wrong", nil, nil)
	resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("连续失败应限流：%d", resp.StatusCode)
	}
}

func TestAdminConfiguresRoutesEndToEnd(t *testing.T) {
	provider, lastRequest := fakeProvider(t)
	h := newHarness(t, map[string]string{
		"ZHIXIN_ADMIN_TOKEN":  testAdminToken,
		"ZHIXIN_LLM_BASE_URL": "http://127.0.0.1:1",
		"ZHIXIN_LLM_API_KEY":  "sk-env-key-9999",
		"ZHIXIN_LLM_MODELS":   "deepseek-flash",
	})
	admin := func(method, path string, in, out any) int {
		t.Helper()
		return h.json(method, path, testAdminToken, in, out)
	}

	// 环境变量来源显示为只读，不能改也不能删。
	var providers struct {
		Data []map[string]any `json:"data"`
	}
	admin("GET", "/admin/v1/providers", nil, &providers)
	if len(providers.Data) != 1 || providers.Data[0]["id"] != "env" || providers.Data[0]["source"] != "env" || providers.Data[0]["key_hint"] != "9999" {
		t.Fatalf("应列出环境变量来源：%+v", providers.Data)
	}
	if code := admin("PUT", "/admin/v1/providers/env", map[string]any{"base_url": "https://x.cn/v1"}, nil); code != http.StatusConflict {
		t.Fatalf("env 是保留名：%d", code)
	}

	// 新建来源：key 不出现在任何响应里。
	resp := h.do("PUT", "/admin/v1/providers/bailian", testAdminToken,
		strings.NewReader(`{"name":"百炼","base_url":"`+provider.URL+`/v1/","api_key":"sk-bailian-secret-1234"}`),
		map[string]string{"Content-Type": "application/json"})
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || strings.Contains(string(body), "secret") {
		t.Fatalf("保存来源：%d %s", resp.StatusCode, body)
	}
	var saved map[string]any
	_ = json.Unmarshal(body, &saved)
	if saved["base_url"] != provider.URL+"/v1" || saved["key_hint"] != "1234" || saved["has_key"] != true {
		t.Fatalf("地址应去掉末尾斜杠、只给末四位：%+v", saved)
	}
	for _, bad := range []map[string]any{
		{"base_url": "ftp://x"}, {"base_url": "https://x.cn/v1?k=1"}, {"base_url": "https://x.cn", "api_key": "a b"}, {"base_url": "https://x.cn", "extra": 1},
	} {
		if code := admin("PUT", "/admin/v1/providers/bad", bad, nil); code != http.StatusBadRequest {
			t.Fatalf("%v 应被拒：%d", bad, code)
		}
	}
	if code := admin("PUT", "/admin/v1/providers/Bad_ID", map[string]any{"base_url": "https://x.cn"}, nil); code != http.StatusBadRequest {
		t.Fatalf("大写编号应被拒：%d", code)
	}

	// 测试来源：用来源自己的 key 请求 /models。
	var probe struct {
		OK     bool     `json:"ok"`
		Models []string `json:"models"`
	}
	if code := admin("POST", "/admin/v1/providers/bailian/test", nil, &probe); code != http.StatusOK || !probe.OK || len(probe.Models) != 2 {
		t.Fatalf("测试来源：%d %+v", code, probe)
	}
	if last := lastRequest(); last != "GET /v1/models Bearer sk-bailian-secret-1234" {
		t.Fatalf("测试应带来源自己的 key：%q", last)
	}

	// 配置一个聊天模型与一个嵌入模型。
	if code := admin("PUT", "/admin/v1/models/zhixin-chat", map[string]any{
		"kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "qwen-plus"}},
	}, nil); code != http.StatusOK {
		t.Fatalf("put chat model: %d", code)
	}
	var model map[string]any
	if code := admin("PUT", "/admin/v1/models/zhixin-embed", map[string]any{
		"kind": "embedding", "dimensions": 3,
		"routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "text-embedding-v4", "max_batch": 10, "weight": 2}},
	}, &model); code != http.StatusOK || model["dimensions"] != float64(3) {
		t.Fatalf("put embedding model: %d %+v", code, model)
	}
	for _, bad := range []map[string]any{
		{"kind": "chat", "dimensions": 3, "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x"}}},
		{"kind": "chat", "routes": []map[string]any{}},
		{"kind": "chat", "routes": []map[string]any{{"provider_id": "nobody", "upstream_model": "x"}}},
		{"kind": "chat", "routes": []map[string]any{{"provider_id": "env", "upstream_model": "x"}}},
		{"kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x", "weight": 0}}},
		{"kind": "rerank", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x"}}},
	} {
		if code := admin("PUT", "/admin/v1/models/bad-model", bad, nil); code != http.StatusBadRequest {
			t.Fatalf("%v 应被拒：%d", bad, code)
		}
	}

	// 客户端立即看到新模型，并按路由调用。
	user, userID := h.register("route-user@b.cn")
	if code := h.json("POST", "/v1/llm/embeddings", user, nil, nil); code != http.StatusForbidden {
		t.Fatalf("未验证邮箱时应拒绝嵌入请求：%d", code)
	}
	h.markEmailVerified(userID)
	var list struct {
		Data []struct {
			ID   string `json:"id"`
			Kind string `json:"kind"`
		} `json:"data"`
	}
	h.json("GET", "/v1/llm/models", user, nil, &list)
	kinds := map[string]string{}
	for _, m := range list.Data {
		kinds[m.ID] = m.Kind
	}
	if kinds["zhixin-chat"] != "chat" || kinds["zhixin-embed"] != "embedding" || kinds["deepseek-flash"] != "chat" {
		t.Fatalf("模型列表应合并后台与环境变量：%+v", list.Data)
	}
	var reply map[string]any
	if code := h.json("POST", "/v1/llm/chat/completions", user, map[string]any{"model": "zhixin-chat", "messages": []any{}}, &reply); code != http.StatusOK {
		t.Fatalf("chat via admin route: %d", code)
	}
	var emb struct {
		Data []struct {
			Embedding []float64 `json:"embedding"`
		} `json:"data"`
	}
	if code := h.json("POST", "/v1/llm/embeddings", user, map[string]any{"model": "zhixin-embed", "input": []string{"a", "b"}}, &emb); code != http.StatusOK || len(emb.Data) != 2 {
		t.Fatalf("embeddings via admin route: %d %+v", code, emb)
	}
	var quota struct {
		Used    int64 `json:"used_tokens"`
		EmbUsed int64 `json:"embedding_used_tokens"`
	}
	h.json("GET", "/v1/llm/quota", user, nil, &quota)
	if quota.Used != 3 || quota.EmbUsed != 4 {
		t.Fatalf("两类用量分开记：%+v", quota)
	}

	// 测试模型：嵌入模型报告维度。
	var mprobe struct {
		OK         bool   `json:"ok"`
		ProviderID string `json:"provider_id"`
		Dimensions int    `json:"dimensions"`
	}
	if code := admin("POST", "/admin/v1/models/zhixin-embed/test", nil, &mprobe); code != http.StatusOK || !mprobe.OK || mprobe.ProviderID != "bailian" || mprobe.Dimensions != 3 {
		t.Fatalf("测试嵌入模型：%d %+v", code, mprobe)
	}
	if code := admin("POST", "/admin/v1/models/zhixin-chat/test", nil, &mprobe); code != http.StatusOK || !mprobe.OK {
		t.Fatalf("测试聊天模型：%d %+v", code, mprobe)
	}

	// 换主机而不重新填 key 会被拒，key 不能被引到别的地址。
	if code := admin("PUT", "/admin/v1/providers/bailian", map[string]any{"base_url": "https://evil.example/v1"}, nil); code != http.StatusBadRequest {
		t.Fatalf("换主机应要求重新填写 key：%d", code)
	}

	// 省略 api_key 保留原值；停用来源之后模型从客户端列表消失。
	if code := admin("PUT", "/admin/v1/providers/bailian", map[string]any{"base_url": provider.URL + "/v1", "enabled": false}, &saved); code != http.StatusOK || saved["key_hint"] != "1234" {
		t.Fatalf("省略 key 应保留：%d %+v", code, saved)
	}
	h.json("GET", "/v1/llm/models", user, nil, &list)
	if len(list.Data) != 1 || list.Data[0].ID != "deepseek-flash" {
		t.Fatalf("停用来源之后它的模型不可用：%+v", list.Data)
	}

	// 被路由引用的来源不能删除；先删模型再删来源。
	var p struct {
		Extra map[string]any `json:"extra"`
	}
	if code := admin("DELETE", "/admin/v1/providers/bailian", nil, &p); code != http.StatusConflict || len(p.Extra["models"].([]any)) != 2 {
		t.Fatalf("被引用的来源应 409 并列出模型：%d %+v", code, p)
	}
	if code := admin("DELETE", "/admin/v1/models/deepseek-flash", nil, nil); code != http.StatusConflict {
		t.Fatalf("环境变量模型不能在后台删除：%d", code)
	}
	for _, name := range []string{"zhixin-chat", "zhixin-embed"} {
		if code := admin("DELETE", "/admin/v1/models/"+name, nil, nil); code != http.StatusNoContent {
			t.Fatalf("delete %s: %d", name, code)
		}
	}
	if code := admin("DELETE", "/admin/v1/providers/bailian", nil, nil); code != http.StatusNoContent {
		t.Fatalf("delete provider: %d", code)
	}
	if code := admin("DELETE", "/admin/v1/providers/bailian", nil, nil); code != http.StatusNotFound {
		t.Fatalf("重复删除应 404：%d", code)
	}
}
