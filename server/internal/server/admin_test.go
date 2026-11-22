package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

const testAdminToken = "admin-token-0123456789abcdef0123456789"

// fakeProvider 同时提供 /models、/responses 与 /embeddings，记录收到的
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
		case "/v1/responses":
			fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":3}}`)
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
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Stream bool }
		_ = json.NewDecoder(r.Body).Decode(&in)
		if in.Stream {
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<html>Service temporarily unavailable</html>")
			return
		}
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":2}}`)
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
			fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"total_tokens\":6}}}\n\n")
			return
		}
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":9}}`)
	}))
	defer backup.Close()
	h := newHarness(t, map[string]string{
		"ZHIXIN_ADMIN_TOKEN": testAdminToken, "ZHIXIN_LLM_REQUIRE_VERIFIED_CONTACT": "0",
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
		admin("POST", "/admin/v1/providers", map[string]string{"id": id, "base_url": baseURL}, nil, http.StatusCreated)
	}
	const backupModel = "org/second+fast"
	admin("POST", "/admin/v1/models", map[string]any{
		"name": "chat-test", "kind": "chat", "routes": []map[string]any{
			{"provider_id": "primary", "upstream_model": "first"},
			{"provider_id": "backup", "upstream_model": backupModel, "priority": 1},
		},
	}, nil, http.StatusCreated)
	admin("POST", "/admin/v1/models", map[string]any{
		"name": "embed-test", "kind": "embedding", "routes": []map[string]any{{"provider_id": "backup", "upstream_model": "embed", "max_batch": 1}},
	}, nil, http.StatusCreated)
	for _, call := range []struct {
		path string
		body map[string]any
	}{
		{"/v1/llm/responses", map[string]any{"model": "chat-test", "input": []any{}}},
		{"/v1/llm/embeddings", map[string]any{"model": "embed-test", "input": []string{"one", "two"}}},
	} {
		if code := h.json("POST", call.path, user, call.body, nil); code != http.StatusOK {
			t.Fatalf("%s: %d", call.path, code)
		}
	}
	stream := h.do("POST", "/v1/llm/responses", user,
		strings.NewReader(`{"model":"chat-test","input":[],"stream":true}`), map[string]string{"Content-Type": "application/json"})
	sse, err := io.ReadAll(stream.Body)
	stream.Body.Close()
	if err != nil || stream.StatusCode != http.StatusOK || !strings.Contains(string(sse), "response.completed") {
		t.Fatalf("stream fallback: %d %q %v", stream.StatusCode, sse, err)
	}
	var probe api.AdminProbe
	// 探测按给定路由走：这里显式指定 backup。路由次序与权重随机，不指定时会
	// 先试可能失败的 primary，结果不确定。
	admin("POST", "/admin/v1/models/chat-test/test?provider_id=backup&upstream_model="+url.QueryEscape(backupModel), nil, &probe, http.StatusOK)
	if !probe.Ok || probe.ProviderId == nil || *probe.ProviderId != "backup" {
		t.Fatalf("probe did not reach the backup route: %+v", probe)
	}
	const probePath = "/admin/v1/models/chat-test/test"
	admin("POST", probePath+"?provider_id=primary", nil, nil, http.StatusBadRequest)
	admin("POST", probePath+"?provider_id=", nil, nil, http.StatusBadRequest)
	admin("POST", probePath+"?provider_id=backup&upstream_model=missing", nil, nil, http.StatusNotFound)
	// 之后两次定向探测各自看自己的结果。
	probe = api.AdminProbe{}
	// 探针现在走 Responses 的整段请求，primary 的整段响应是正常 JSON，所以
	// 这一条仍然成功；指定的路由本身出现在结果里。
	admin("POST", probePath+"?provider_id=primary&upstream_model=first", nil, &probe, http.StatusOK)
	if !probe.Ok || probe.ProviderId == nil || *probe.ProviderId != "primary" {
		t.Fatalf("targeted probe should stay on the given route: %+v", probe)
	}
	probe = api.AdminProbe{}
	admin("POST", probePath+"?provider_id=backup&upstream_model="+url.QueryEscape(backupModel), nil, &probe, http.StatusOK)
	if !probe.Ok || probe.UpstreamModel == nil || *probe.UpstreamModel != backupModel {
		t.Fatalf("targeted probe did not reach the selected model: %+v", probe)
	}
	admin("GET", "/admin/v1/usage?days=1", nil, &report, http.StatusOK)
	if len(report.Daily) != 1 || len(report.Routes) != 3 {
		t.Fatalf("route usage: %+v", report)
	}
	day := report.Daily[0]
	// 三次对话请求：流式那一次先被 primary 的故障页挡回来、由 backup 接住，
	// 后两次探针各走一条指定路由。数位按各来源自己的用量核对，所以这里只核对
	// 次数与「实际用量不低于估算」。
	if day.Chat.Attempts != 3 || day.Chat.Successes != 2 || day.Chat.EstimatedTokens <= 0 ||
		day.Chat.Tokens < day.Chat.EstimatedTokens || day.Embedding != (api.AdminUsageCounts{
		Attempts: 1, Successes: 1, Tokens: 10, EstimatedTokens: 3,
	}) {
		t.Fatalf("daily totals: %+v", day)
	}
	for _, route := range report.Routes {
		if len(route.Daily) != 1 || route.Daily[day.Day.Format("2006-01-02")] != route.Usage {
			t.Fatalf("single-day route breakdown: %+v", route)
		}
		switch {
		case route.ProviderId == "primary" && (route.Usage.Successes != 1 || route.Usage.Attempts != 2):
			t.Fatalf("primary: %+v", route)
		case route.UpstreamModel == backupModel && route.Usage.Successes != 1:
			t.Fatalf("fallback: %+v", route)
		}
	}
	yesterday := day.Day.AddDate(0, 0, -1).Format("2006-01-02")
	if err := h.stores.Usage.AddRouteUsage(context.Background(), llmproxy.RouteUsage{
		Day: yesterday,
		RouteUsageKey: llmproxy.RouteUsageKey{
			Kind: llmproxy.KindChat, Model: "chat-test", ProviderID: "backup", UpstreamModel: backupModel,
		},
		UsageCounts: llmproxy.UsageCounts{Attempts: 1, Successes: 1, Tokens: 4},
	}); err != nil {
		t.Fatal(err)
	}
	admin("GET", "/admin/v1/usage?days=7", nil, &report, http.StatusOK)
	if len(report.Daily) != 7 || len(report.Routes) != 3 {
		t.Fatalf("seven-day report: %+v", report)
	}
	for _, route := range report.Routes {
		if route.UpstreamModel == backupModel && (len(route.Daily) != 2 ||
			route.Daily[yesterday].Tokens != 4 || route.Usage.Tokens != 10) {
			t.Fatalf("route breakdown across dates: %+v", route)
		}
	}
	admin("PUT", "/admin/v1/providers/backup", map[string]any{"base_url": backup.URL, "enabled": false}, nil, http.StatusOK)
	probe = api.AdminProbe{}
	admin("POST", probePath+"?provider_id=backup&upstream_model="+url.QueryEscape(backupModel), nil, &probe, http.StatusOK)
	if probe.Ok || probe.Error == nil {
		t.Fatalf("disabled route was probed: %+v", probe)
	}
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
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	admin := func(method, path string, in, out any) int {
		t.Helper()
		return h.json(method, path, testAdminToken, in, out)
	}

	// 新实例没有来源，托管接口也没有模型可用。
	var providers struct {
		Data []map[string]any `json:"data"`
	}
	admin("GET", "/admin/v1/providers", nil, &providers)
	if len(providers.Data) != 0 {
		t.Fatalf("新实例不应有来源：%+v", providers.Data)
	}

	// 新建来源：key 不出现在任何响应里。
	resp := h.do("POST", "/admin/v1/providers", testAdminToken,
		strings.NewReader(`{"id":"bailian","name":"百炼","base_url":"`+provider.URL+`/v1/","api_key":"sk-bailian-secret-1234"}`),
		map[string]string{"Content-Type": "application/json"})
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated || strings.Contains(string(body), "secret") {
		t.Fatalf("保存来源：%d %s", resp.StatusCode, body)
	}
	var saved map[string]any
	_ = json.Unmarshal(body, &saved)
	if saved["base_url"] != provider.URL+"/v1" || saved["key_hint"] != "1234" || saved["has_key"] != true {
		t.Fatalf("地址应去掉末尾斜杠、只给末四位：%+v", saved)
	}
	for _, bad := range []map[string]any{
		{"id": "bad", "base_url": "ftp://x"}, {"id": "bad", "base_url": "https://x.cn/v1?k=1"},
		{"id": "bad", "base_url": "https://x.cn", "api_key": "a b"}, {"id": "bad", "base_url": "https://x.cn", "extra": 1},
	} {
		if code := admin("POST", "/admin/v1/providers", bad, nil); code != http.StatusBadRequest {
			t.Fatalf("%v 应被拒：%d", bad, code)
		}
	}
	if code := admin("POST", "/admin/v1/providers", map[string]any{"id": "Bad_ID", "base_url": "https://x.cn"}, nil); code != http.StatusBadRequest {
		t.Fatalf("大写编号应被拒：%d", code)
	}
	// 重复编号不能覆盖已有来源。
	if code := h.json("POST", "/admin/v1/providers", testAdminToken,
		map[string]any{"id": "bailian", "base_url": provider.URL + "/v1"}, nil); code != http.StatusConflict {
		t.Fatalf("重复编号应 409：%d", code)
	}
	if code := admin("PUT", "/admin/v1/providers/absent", map[string]any{"base_url": "https://x.cn"}, nil); code != http.StatusNotFound {
		t.Fatalf("修改不存在的来源应 404：%d", code)
	}
	if code := admin("POST", "/admin/v1/models", map[string]any{
		"kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x"}},
	}, nil); code != http.StatusBadRequest {
		t.Fatalf("新建模型缺少名称应 400：%d", code)
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
	if code := admin("POST", "/admin/v1/models", map[string]any{
		"name": "zhixin-chat", "kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "qwen-plus"}},
	}, nil); code != http.StatusCreated {
		t.Fatalf("put chat model: %d", code)
	}
	var model map[string]any
	if code := admin("POST", "/admin/v1/models", map[string]any{
		"name": "zhixin-embed", "kind": "embedding", "dimensions": 3,
		"routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "text-embedding-v4", "max_batch": 10, "weight": 2}},
	}, &model); code != http.StatusCreated || model["dimensions"] != float64(3) {
		t.Fatalf("put embedding model: %d %+v", code, model)
	}
	// 新增表单误填已有名称时不能静默覆盖。
	if code := h.json("POST", "/admin/v1/models", testAdminToken,
		map[string]any{"name": "zhixin-chat", "kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "other"}}}, nil); code != http.StatusConflict {
		t.Fatalf("重复模型名应 409：%d", code)
	}
	// 修改不存在的模型返回 404。
	if code := admin("PUT", "/admin/v1/models/absent", map[string]any{"kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x"}}}, nil); code != http.StatusNotFound {
		t.Fatalf("修改不存在的模型应 404：%d", code)
	}
	for _, bad := range []map[string]any{
		{"name": "bad-model", "kind": "chat", "dimensions": 3, "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x"}}},
		{"name": "bad-model", "kind": "chat", "routes": []map[string]any{}},
		{"name": "bad-model", "kind": "chat", "routes": []map[string]any{{"provider_id": "nobody", "upstream_model": "x"}}},
		{"name": "bad-model", "kind": "chat", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x", "weight": 0}}},
		{"name": "bad-model", "kind": "rerank", "routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "x"}}},
	} {
		if code := admin("POST", "/admin/v1/models", bad, nil); code != http.StatusBadRequest {
			t.Fatalf("%v 应被拒：%d", bad, code)
		}
	}

	// 客户端立即看到新模型，并按路由调用。
	user, userID := h.register("route-user@b.cn")
	if code := h.json("POST", "/v1/llm/embeddings", user, nil, nil); code != http.StatusForbidden {
		t.Fatalf("未验证邮箱时应拒绝嵌入请求：%d", code)
	}
	h.markContactVerified(userID)
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
	if kinds["zhixin-chat"] != "chat" || kinds["zhixin-embed"] != "embedding" || len(kinds) != 2 {
		t.Fatalf("模型列表应只含后台配置的模型：%+v", list.Data)
	}
	var reply map[string]any
	if code := h.json("POST", "/v1/llm/responses", user, map[string]any{"model": "zhixin-chat", "input": []any{}}, &reply); code != http.StatusOK {
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
	if len(list.Data) != 0 {
		t.Fatalf("停用来源之后它的模型不可用：%+v", list.Data)
	}

	// 被路由引用的来源不能删除；先删模型再删来源。
	var p struct {
		Extra map[string]any `json:"extra"`
	}
	if code := admin("DELETE", "/admin/v1/providers/bailian", nil, &p); code != http.StatusConflict || len(p.Extra["models"].([]any)) != 2 {
		t.Fatalf("被引用的来源应 409 并列出模型：%d %+v", code, p)
	}
	if code := admin("DELETE", "/admin/v1/models/nope", nil, nil); code != http.StatusNotFound {
		t.Fatalf("不存在的模型应回 404：%d", code)
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
