package llmproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	p *Proxy
}

func (a testAPI) GetV1LlmModels(w http.ResponseWriter, r *http.Request) { a.p.Models(w, r) }
func (a testAPI) GetV1LlmQuota(w http.ResponseWriter, r *http.Request)  { a.p.QuotaStatus(w, r) }
func (a testAPI) PostV1LlmResponses(w http.ResponseWriter, r *http.Request) {
	a.p.Responses(w, r)
}
func (a testAPI) PostV1LlmEmbeddings(w http.ResponseWriter, r *http.Request, _ api.PostV1LlmEmbeddingsParams) {
	a.p.Embeddings(w, r)
}
func (a testAPI) PostV1LlmEmbeddingsLookup(w http.ResponseWriter, r *http.Request) {
	a.p.EmbeddingLookup(w, r)
}

type testEnv struct {
	c       *testutil.Client
	authSvc *auth.Service
	quota   *MemoryQuota
	catalog *MemoryCatalog
	box     *secretbox.Box
	proxy   *Proxy
}

func baseConfig() config.LLMConfig {
	return config.LLMConfig{
		DailyTokens:          10000,
		EmbeddingDailyTokens: 10000,
		MaxRequestBytes:      1 << 20,
		EmbeddingMaxInputs:   8,
		MaxAttempts:          3,
		HeaderTimeout:        2 * time.Second,
	}
}

// newTestServer 装配本包处理器与鉴权中间件。cfg 里的 BaseURL 与 APIKey 构成
// 环境变量来源；setup 可以在第一次读路由之前往内存 Catalog 里写来源与模型。
func newTestServer(t *testing.T, cfg config.LLMConfig, setup func(*MemoryCatalog, *secretbox.Box)) *testEnv {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	quota := NewMemoryQuota()
	catalog := NewMemoryCatalog()
	box := secretbox.Random()
	if setup != nil {
		setup(catalog, box)
	}
	router := NewRouter(catalog, box, log)
	// 测试里不随机：同一优先级保持配置顺序。
	router.shuffle = func([]liveRoute) {}
	if err := router.Reload(context.Background()); err != nil {
		t.Fatal(err)
	}
	proxy := NewRoutedHandler(cfg, router, quota, time.UTC, log)
	c := testutil.NewClient(t, testutil.NewServer(
		testAPI{p: proxy},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	))
	return &testEnv{c: c, authSvc: authSvc, quota: quota, catalog: catalog, box: box, proxy: proxy}
}

// signIn 注册一个测试账号并返回访问令牌。
func signIn(t *testing.T, svc *auth.Service, email string) string {
	t.Helper()
	tokens, err := svc.Register(context.Background(), email, "password1", "")
	if err != nil {
		t.Fatalf("register %s: %v", email, err)
	}
	return tokens.AccessToken
}

func putProvider(t *testing.T, c *MemoryCatalog, box *secretbox.Box, id, url, key string) {
	t.Helper()
	sealed, err := box.Seal(key, KeyAAD(id, url))
	if err != nil {
		t.Fatal(err)
	}
	if err := c.PutProvider(context.Background(), ProviderRecord{
		ID: id, Name: id, BaseURL: url, APIKeySealed: sealed, KeyHint: keyHint(key), Enabled: true, UpdatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
}

func putModel(t *testing.T, c *MemoryCatalog, m ModelRecord) {
	t.Helper()
	m.Enabled = true
	m.UpdatedAt = time.Now()
	for i := range m.Routes {
		m.Routes[i].Enabled = true
		if m.Routes[i].Weight == 0 {
			m.Routes[i].Weight = 1
		}
	}
	if err := c.PutModel(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

func TestHandlerLLMProxy(t *testing.T) {
	var gotAuth string
	var gotBody map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你\"}\n\n")
		w.(http.Flusher).Flush()
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"total_tokens\":120}}}\n\n")

	}))
	defer upstream.Close()

	// 一次请求按请求字节加默认输出上限预留，额度 8400 够第一次。
	cfg := baseConfig()
	cfg.DailyTokens = 8400
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "up", upstream.URL, "sk-server")
		putModel(t, c, ModelRecord{Name: "deepseek-flash", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "deepseek-flash"}}})
	})
	c := env.c
	tokens, err := env.authSvc.Register(context.Background(), "a@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	token := tokens.AccessToken

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "gpt-x"}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeModelNotAllowed) {
		t.Fatalf("model check: %d %+v", code, p)
	}

	req := map[string]any{"model": "deepseek-flash", "stream": true, "input": []any{map[string]string{"role": "user", "content": "hi"}}}
	b, _ := json.Marshal(req)
	stream := testutil.ReadBody(t, c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(b), nil))
	if !strings.Contains(string(stream), "你") || !strings.Contains(string(stream), "response.completed") {
		t.Fatalf("stream: %q", stream)
	}
	if gotAuth != "Bearer sk-server" {
		t.Fatalf("upstream auth = %q; the client token must not be forwarded", gotAuth)
	}
	if gotBody["model"] != "deepseek-flash" || gotBody["stream"] != true {
		t.Fatalf("body not forwarded: %+v", gotBody)
	}

	var q struct {
		Used         int64 `json:"used_tokens"`
		EmbeddingCap int64 `json:"embedding_daily_tokens"`
	}
	if code := c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q); code != http.StatusOK || q.Used != 120 || q.EmbeddingCap != 10000 {
		t.Fatalf("usage: %d %+v", code, q)
	}
	// 额度内再发一次应当通过。
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, req, nil); code != http.StatusOK {
		t.Fatalf("额度内应通过，得到 %d", code)
	}
	// 额度调到不足一次预留之后，下一次请求按额度用完拒绝。
	env.quota.SetDailyLimit(tokens.UserID, 100)
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, req, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeQuotaExceeded) {
		t.Fatalf("quota: %d %+v", code, p)
	}
}

// TestHandlerResponsesForcesStoreOff 断言服务端转发给来源的 `store` 恒为
// false：客户端发 true、发 false 或不发这个字段，上游收到的都是 false。
// Responses 创建接口在缺少该字段时默认让上游保存响应，所以既不能删掉它，也不
// 能照抄客户端给出的值。
func TestHandlerResponsesForcesStoreOff(t *testing.T) {
	var gotBody map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"resp_1","object":"response","status":"completed","output":[]}`)
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "up", upstream.URL, "sk-server")
		putModel(t, c, ModelRecord{Name: "deepseek-flash", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "deepseek-flash"}}})
	})
	tokens, err := env.authSvc.Register(context.Background(), "store@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	token := tokens.AccessToken
	// 三次请求都要真正到达上游：额度放宽到不会在中途拒绝。
	env.quota.SetDailyLimit(tokens.UserID, 1<<30)

	for _, tc := range []struct {
		name string
		req  map[string]any
	}{
		{"客户端发 false", map[string]any{"model": "deepseek-flash", "input": []any{}, "store": false}},
		{"客户端发 true", map[string]any{"model": "deepseek-flash", "input": []any{}, "store": true}},
		{"客户端不发", map[string]any{"model": "deepseek-flash", "input": []any{}}},
	} {
		gotBody = nil
		req, err := json.Marshal(tc.req)
		if err != nil {
			t.Fatal(err)
		}
		// 只看状态码：testutil.Client.JSON 会把成功响应也解成 Problem。
		resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(req), map[string]string{"Content-Type": "application/json"})
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s：应放行，得到 %d", tc.name, resp.StatusCode)
		}
		store, present := gotBody["store"]
		if !present || store != false {
			t.Fatalf("%s：上游收到的 store 应为 false，得到 %v（存在 %v）", tc.name, store, present)
		}
		if gotBody["model"] != "deepseek-flash" {
			t.Fatalf("%s：模型名应换成来源侧名字，得到 %v", tc.name, gotBody["model"])
		}
	}
}

func TestHandlerQuotaOverride(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"total_tokens\":120}}}\n\n")

	}))
	defer upstream.Close()

	cfg := baseConfig()
	cfg.DailyTokens = 8400
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "up", upstream.URL, "sk-server")
		putModel(t, c, ModelRecord{Name: "deepseek-flash", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "deepseek-flash"}}})
	})
	c, quota := env.c, env.quota
	tokens, err := env.authSvc.Register(context.Background(), "override@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	token := tokens.AccessToken
	chat := map[string]any{
		"model": "deepseek-flash", "stream": true,
		"input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}},
	}

	// 默认额度 8400 用得完：先按默认额度发一次，再降到不足一次预留，触发拒绝并
	// 记下拒绝时返回的额度。
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusOK {
		t.Fatalf("第一次请求应通过，得到 %d", code)
	}
	var p testutil.Problem
	quota.SetDailyLimit(tokens.UserID, 100)
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeQuotaExceeded) {
		t.Fatalf("额度不足一次预留时应被拒：%d %+v", code, p)
	}

	// 调高这个账号之后，同样的用量不再被拒。
	quota.SetDailyLimit(tokens.UserID, 20000)
	var q struct {
		Used        int64 `json:"used_tokens"`
		DailyTokens int64 `json:"daily_tokens"`
	}
	if code := c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q); code != http.StatusOK || q.DailyTokens != 20000 || q.Used != 120 {
		t.Fatalf("额度接口应返回调整后的值：%d %+v", code, q)
	}
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusOK {
		t.Fatalf("调整之后应通过，得到 %d", code)
	}

	// 调低之后立即生效，被拒时 extra 里带的是调整后的额度。
	quota.SetDailyLimit(tokens.UserID, 100)
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, &p); code != http.StatusTooManyRequests {
		t.Fatalf("调低之后应被拒，得到 %d", code)
	}
	if got, _ := p.Extra["daily_tokens"].(float64); got != 100 {
		t.Fatalf("被拒的额度应为调整后的 100，得到 %v", p.Extra)
	}
}

func TestHandlerLLMProxyWithoutSources(t *testing.T) {
	cfg := baseConfig()
	env := newTestServer(t, cfg, nil)
	token := signIn(t, env.authSvc, "a@b.cn")

	var p testutil.Problem
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "deepseek-flash"}, &p); code != http.StatusServiceUnavailable || p.Code != string(httpx.CodeUnavailable) {
		t.Fatalf("got %d %+v", code, p)
	}
	var list struct {
		Data []any `json:"data"`
	}
	if code := env.c.JSON(http.MethodGet, "/v1/llm/models", token, nil, &list); code != http.StatusOK || len(list.Data) != 0 {
		t.Fatalf("没有可用来源时模型列表应为空：%d %+v", code, list)
	}
}

// fakeSource 是一个可编程的上游：status 决定返回码，记录收到的模型名与 key。
type fakeSource struct {
	*httptest.Server
	calls  atomic.Int64
	status atomic.Int64
	mu     sync.Mutex
	models []string
	keys   []string
}

func newFakeSource(t *testing.T, tag string) *fakeSource {
	t.Helper()
	f := &fakeSource{}
	f.status.Store(http.StatusOK)
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		var body struct {
			Model string `json:"model"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.models = append(f.models, body.Model)
		f.keys = append(f.keys, r.Header.Get("Authorization"))
		f.mu.Unlock()
		status := int(f.status.Load())
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if status != http.StatusOK {
			fmt.Fprintf(w, `{"error":{"message":"%s says %d"}}`, tag, status)
			return
		}
		fmt.Fprintf(w, `{"id":"resp_1","object":"response","output":[],"usage":{"total_tokens":7},"tag":"%s"}`, tag)
	}))
	t.Cleanup(f.Close)
	return f
}

func TestChatFailsOverToNextSource(t *testing.T) {
	primary := newFakeSource(t, "primary")
	backup := newFakeSource(t, "backup")
	primary.status.Store(http.StatusServiceUnavailable)

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "primary", primary.URL, "sk-primary")
		putProvider(t, c, box, "backup", backup.URL, "sk-backup")
		putModel(t, c, ModelRecord{Name: "zhixin-chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "primary", UpstreamModel: "deepseek-chat", Priority: 0},
			{ProviderID: "backup", UpstreamModel: "qwen-plus", Priority: 1},
		}})
	})
	tokens, err := env.authSvc.Register(context.Background(), "f@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	token := tokens.AccessToken
	// 四次请求都按默认输出上限预留，额度要够整轮失败重试。
	env.quota.SetDailyLimit(tokens.UserID, 25000)
	chat := map[string]any{"model": "zhixin-chat", "input": []any{}}

	for i := range 3 {
		var out struct {
			Tag string `json:"tag"`
		}
		if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, &out); code != http.StatusOK || out.Tag != "backup" {
			t.Fatalf("第 %d 次应由备用来源回答：%d %+v", i+1, code, out)
		}
	}
	if primary.models[0] != "deepseek-chat" || backup.models[0] != "qwen-plus" {
		t.Fatalf("model 应换成来源侧名字：%v %v", primary.models, backup.models)
	}
	if primary.keys[0] != "Bearer sk-primary" || backup.keys[0] != "Bearer sk-backup" {
		t.Fatalf("各来源应收到自己的 key：%v %v", primary.keys, backup.keys)
	}
	// HTTP 503 可能是模型故障，连续三次后只冷却这条路由。
	model, _ := env.proxy.router.current().model("zhixin-chat")
	states := env.proxy.router.health.modelViews(model)
	if states[0].route.phase != healthCooling || states[0].source.phase != healthReady {
		t.Fatalf("主路由应单独进入冷却：%+v", states[0])
	}
	before := primary.calls.Load()
	env.c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil)
	if primary.calls.Load() != before {
		t.Fatal("冷却中的来源不应先被尝试")
	}
	var used struct {
		Used int64 `json:"used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &used)
	if used.Used <= 4*7 {
		t.Fatalf("总用量应包含三次结果不确定的尝试：%+v", used)
	}
}

func TestChatPassesThroughClientErrorsWithoutFailover(t *testing.T) {
	primary := newFakeSource(t, "primary")
	backup := newFakeSource(t, "backup")
	primary.status.Store(http.StatusBadRequest)

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "primary", primary.URL, "sk-primary")
		putProvider(t, c, box, "backup", backup.URL, "sk-backup")
		putModel(t, c, ModelRecord{Name: "zhixin-chat", Kind: KindChat, Routes: []Route{
			{ProviderID: "primary", UpstreamModel: "a"}, {ProviderID: "backup", UpstreamModel: "b", Priority: 1},
		}})
	})
	token := signIn(t, env.authSvc, "g@b.cn")
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, strings.NewReader(`{"model":"zhixin-chat","input":[]}`), nil)
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusBadRequest || strings.Contains(string(body), "primary says 400") {
		t.Fatalf("400 应保留状态并替换响应体：%d %s", resp.StatusCode, body)
	}
	if backup.calls.Load() != 0 {
		t.Fatal("请求本身有问题时不应换来源")
	}

	// 最后一个来源也失败时，把它的状态与响应体交给客户端。
	primary.status.Store(http.StatusTooManyRequests)
	backup.status.Store(http.StatusInternalServerError)
	resp = env.c.Do(http.MethodPost, "/v1/llm/responses", token, strings.NewReader(`{"model":"zhixin-chat","input":[]}`), nil)
	body = testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusInternalServerError || strings.Contains(string(body), "backup says 500") {
		t.Fatalf("全部失败时应保留最后一个来源的状态：%d %s", resp.StatusCode, body)
	}
}

func TestChatUnreachableSourcesGive502(t *testing.T) {
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "dead", "http://127.0.0.1:1", "sk-dead")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{{ProviderID: "dead", UpstreamModel: "x"}}})
	})
	token := signIn(t, env.authSvc, "h@b.cn")
	var p testutil.Problem
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "m", "input": []any{}}, &p); code != http.StatusBadGateway || p.Code != string(httpx.CodeUpstreamFailed) {
		t.Fatalf("got %d %+v", code, p)
	}
}

func TestChatConnectionFailureSkipsSiblingRoutes(t *testing.T) {
	backup := newFakeSource(t, "backup")
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "primary", dead.URL, "sk-primary")
		putProvider(t, c, box, "backup", backup.URL, "sk-backup")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "primary", UpstreamModel: "a", Priority: 0},
			{ProviderID: "primary", UpstreamModel: "b", Priority: 1},
			{ProviderID: "primary", UpstreamModel: "c", Priority: 2},
			{ProviderID: "backup", UpstreamModel: "d", Priority: 3},
		}})
	})
	token := signIn(t, env.authSvc, "connect@example.test")
	var out struct{ Tag string }
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "m", "input": []any{}}, &out); code != http.StatusOK || out.Tag != "backup" {
		t.Fatalf("连接失败后应跳过同来源路由并调用备用来源：%d %+v", code, out)
	}
	health := env.proxy.router.health.view(healthKey{provider: "primary"})
	if health.failures != 1 {
		t.Fatalf("主来源只应尝试一次：%+v", health)
	}
	env.proxy.cfg.MaxAttempts = 1
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "m", "input": []any{}}, nil); code != http.StatusBadGateway || backup.calls.Load() != 1 {
		t.Fatalf("实际尝试用完后应停止切换：状态 %d，备用调用 %d", code, backup.calls.Load())
	}
}

func TestChatUpstreamRateLimitPassesRetryAfter(t *testing.T) {
	limited := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "7")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer limited.Close()
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "limited", limited.URL, "sk-limited")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "limited", UpstreamModel: "a"},
		}})
	})
	token := signIn(t, env.authSvc, "busy@example.test")
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		strings.NewReader(`{"model":"m","input":[]}`), map[string]string{"Content-Type": "application/json"})
	defer resp.Body.Close()
	problem := testutil.ReadProblem(t, resp)
	if resp.StatusCode != http.StatusTooManyRequests || problem.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("上游限流应转成 429 rate_limited：%d %+v", resp.StatusCode, problem)
	}
	if got := resp.Header.Get("Retry-After"); got != "7" {
		t.Fatalf("Retry-After 应原样转给客户端，得到 %q", got)
	}
}

func TestCandidatesOrder(t *testing.T) {
	a := &liveProvider{ProviderRecord: ProviderRecord{ID: "a", Enabled: true}}
	b := &liveProvider{ProviderRecord: ProviderRecord{ID: "b", Enabled: true}}
	c := &liveProvider{ProviderRecord: ProviderRecord{ID: "c", Enabled: true}}
	off := &liveProvider{ProviderRecord: ProviderRecord{ID: "off", Enabled: false}}
	broken := &liveProvider{ProviderRecord: ProviderRecord{ID: "broken", Enabled: true}, KeyBroken: true}
	m := &liveModel{ModelRecord: ModelRecord{Enabled: true}, Live: []liveRoute{
		{Route: Route{Priority: 5, Weight: 1, Enabled: true}, Provider: c},
		{Route: Route{Priority: 0, Weight: 1, Enabled: true}, Provider: off},
		{Route: Route{Priority: 0, Weight: 1, Enabled: true}, Provider: a},
		{Route: Route{Priority: 0, Weight: 1, Enabled: false}, Provider: b},
		{Route: Route{Priority: 1, Weight: 1, Enabled: true}, Provider: b},
		{Route: Route{Priority: 0, Weight: 1, Enabled: true}, Provider: broken},
	}}
	now := time.Now()
	r := &Router{health: newHealthBook(func() time.Time { return now }), shuffle: func([]liveRoute) {}}
	ids := func(rs []liveRoute) string {
		var s []string
		for _, rt := range rs {
			s = append(s, rt.Provider.ID)
		}
		return strings.Join(s, ",")
	}
	if got := ids(r.candidates(m)); got != "a,b,c" {
		t.Fatalf("按优先级排列并跳过停用与 key 损坏的来源：%s", got)
	}
	for range coolAfterFailures {
		lease, ok := r.health.acquire(m, m.Live[2], false)
		if !ok {
			t.Fatal("冷却前应能尝试")
		}
		r.health.complete(lease, false, healthOutcome{reason: "无法连接", scope: sourceFailure})
	}
	if got := ids(r.candidates(m)); got != "b,c" {
		t.Fatalf("冷却中的来源应跳过：%s", got)
	}
	now = now.Add(coolBase)
	if got := ids(r.candidates(m)); got != "a,b,c" {
		t.Fatalf("冷却到期后按原优先级试探：%s", got)
	}
}

func TestWeightedShuffleFavoursHeavierRoutes(t *testing.T) {
	heavy := &liveProvider{ProviderRecord: ProviderRecord{ID: "heavy"}}
	light := &liveProvider{ProviderRecord: ProviderRecord{ID: "light"}}
	first := map[string]int{}
	for range 2000 {
		rs := []liveRoute{{Route: Route{Weight: 1}, Provider: light}, {Route: Route{Weight: 9}, Provider: heavy}}
		weightedShuffle(rs)
		first[rs[0].Provider.ID]++
	}
	// 权重 9:1，重的一条排第一的概率是 0.9；给足余量避免偶发失败。
	if first["heavy"] < 1600 || first["light"] < 80 {
		t.Fatalf("权重分流不符合预期：%v", first)
	}
}

func TestBrokenKeyMakesModelUnavailable(t *testing.T) {
	src := newFakeSource(t, "x")
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, _ *secretbox.Box) {
		// 用另一把密钥加密：当前密钥解不开。
		putProvider(t, c, secretbox.Random(), "p", src.URL, "sk-other")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{{ProviderID: "p", UpstreamModel: "x"}}})
	})
	token := signIn(t, env.authSvc, "k@b.cn")
	var p testutil.Problem
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "m", "input": []any{}}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeModelNotAllowed) {
		t.Fatalf("key 无法解密时模型不可用：%d %+v", code, p)
	}
	if src.calls.Load() != 0 {
		t.Fatal("不应带着空 key 去请求来源")
	}
}

// embedSource 返回的向量第一个分量是来源编号，第二个分量是输入 text-N 里的
// N，便于核对合并顺序与来源。data 按倒序返回，核对服务端按 index 排序。
type embedSource struct {
	*httptest.Server
	calls   atomic.Int64
	batches [][]string
	mu      sync.Mutex
	failOn  int // 第几次调用返回 500，0 表示不失败
	dims    int
	noUsage bool
}

func newEmbedSource(t *testing.T, tag float64, dims int) *embedSource {
	t.Helper()
	e := &embedSource{dims: dims}
	e.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := e.calls.Add(1)
		var body struct {
			Model string   `json:"model"`
			Input []string `json:"input"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		e.mu.Lock()
		e.batches = append(e.batches, body.Input)
		e.mu.Unlock()
		if e.failOn != 0 && int(n) == e.failOn {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		var data []string
		for i := len(body.Input) - 1; i >= 0; i-- {
			vec := make([]string, e.dims)
			for d := range vec {
				vec[d] = "0"
			}
			vec[0] = fmt.Sprint(tag)
			vec[1] = body.Input[i][len("text-"):]
			data = append(data, fmt.Sprintf(`{"object":"embedding","index":%d,"embedding":[%s]}`, i, strings.Join(vec, ",")))
		}
		usage := fmt.Sprintf(`,"usage":{"prompt_tokens":%d,"total_tokens":%d}`, 3*len(body.Input), 3*len(body.Input))
		if e.noUsage {
			usage = ""
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"object":"list","model":"%s","data":[%s]%s}`, body.Model, strings.Join(data, ","), usage)
	}))
	t.Cleanup(e.Close)
	return e
}

type embedOut struct {
	Model string `json:"model"`
	Data  []struct {
		Index     int       `json:"index"`
		Embedding []float64 `json:"embedding"`
	} `json:"data"`
	Usage struct {
		TotalTokens int64 `json:"total_tokens"`
	} `json:"usage"`
}

func inputs(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("text-%d", i)
	}
	return out
}

func TestEmbeddingsSplitAndMerge(t *testing.T) {
	src := newEmbedSource(t, 1, 4)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "sf", src.URL, "sk-sf")
		putModel(t, c, ModelRecord{Name: "zhixin-embed", Kind: KindEmbedding, Dimensions: 4, Routes: []Route{
			{ProviderID: "sf", UpstreamModel: "BAAI/bge-m3", MaxBatch: 2},
		}})
	})
	token := signIn(t, env.authSvc, "e@b.cn")

	var out embedOut
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "zhixin-embed", "input": inputs(5)}, &out); code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}
	if src.calls.Load() != 3 {
		t.Fatalf("5 条按每批 2 条应拆成 3 批，实际 %d", src.calls.Load())
	}
	if out.Model != "zhixin-embed" || len(out.Data) != 5 {
		t.Fatalf("响应：%+v", out)
	}
	for i, d := range out.Data {
		if d.Index != i || len(d.Embedding) != 4 {
			t.Fatalf("第 %d 条：%+v", i, d)
		}
	}
	// 第二个分量是输入的编号：来源按倒序返回，合并之后仍按原顺序排列。
	for i, d := range out.Data {
		if d.Embedding[1] != float64(i) {
			t.Fatalf("合并顺序不对：第 %d 条 %v", i, d.Embedding)
		}
	}
	if out.Usage.TotalTokens != 15 {
		t.Fatalf("用量应合计：%+v", out.Usage)
	}

	var q struct {
		Used    int64 `json:"used_tokens"`
		EmbUsed int64 `json:"embedding_used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q)
	if q.Used != 0 || q.EmbUsed != 15 {
		t.Fatalf("嵌入用量应记在嵌入额度上：%+v", q)
	}

	var list struct {
		Data []struct {
			ID         string `json:"id"`
			Kind       string `json:"kind"`
			Dimensions int    `json:"dimensions"`
		} `json:"data"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/models", token, nil, &list)
	if len(list.Data) != 1 || list.Data[0].Kind != "embedding" || list.Data[0].Dimensions != 4 {
		t.Fatalf("模型列表应带种类与维度：%+v", list)
	}

	// 单个字符串也接受。
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "zhixin-embed", "input": "text-9"}, &out); code != http.StatusOK || len(out.Data) != 1 {
		t.Fatalf("single input: %d %+v", code, out)
	}
	// 聊天接口不接受嵌入模型。
	var p testutil.Problem
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", token, map[string]any{"model": "zhixin-embed"}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeModelNotAllowed) {
		t.Fatalf("嵌入模型不能用于聊天：%d %+v", code, p)
	}
}

func TestEmbeddingsFailoverRedoesWholeRequest(t *testing.T) {
	first := newEmbedSource(t, 1, 4)
	first.failOn = 2 // 第二批失败
	second := newEmbedSource(t, 2, 4)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "one", first.URL, "sk-1")
		putProvider(t, c, box, "two", second.URL, "sk-2")
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Routes: []Route{
			{ProviderID: "one", UpstreamModel: "bge-m3", MaxBatch: 2},
			{ProviderID: "two", UpstreamModel: "bge-m3", MaxBatch: 4, Priority: 1},
		}})
	})
	token := signIn(t, env.authSvc, "ef@b.cn")
	var out embedOut
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "emb", "input": inputs(4)}, &out); code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}
	for _, d := range out.Data {
		if d.Embedding[0] != 2 {
			t.Fatalf("一批失败后整次请求应改由第二个来源完成，不能混用：%+v", out.Data)
		}
	}
	if second.calls.Load() != 1 {
		t.Fatalf("第二个来源每批 4 条，应只调用一次：%d", second.calls.Load())
	}
}

func TestEmbeddingsSharedCredentialFailureLeavesAttemptForBackup(t *testing.T) {
	var rejected atomic.Int64
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rejected.Add(1)
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer primary.Close()
	backup := newEmbedSource(t, 2, 4)
	cfg := baseConfig()
	cfg.MaxAttempts = 2
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "primary", primary.URL, "sk-1")
		putProvider(t, c, box, "backup", backup.URL, "sk-2")
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Dimensions: 4, Routes: []Route{
			{ProviderID: "primary", UpstreamModel: "first"},
			{ProviderID: "primary", UpstreamModel: "second", Priority: 1},
			{ProviderID: "backup", UpstreamModel: "backup", Priority: 2},
		}})
	})
	token := signIn(t, env.authSvc, "embed-retry@example.test")
	var out embedOut
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "emb", "input": inputs(1)}, &out); code != http.StatusOK || len(out.Data) != 1 || len(out.Data[0].Embedding) != 4 || out.Data[0].Embedding[0] != 2 {
		t.Fatalf("共享密钥被拒后应切换到备用来源：%d %+v", code, out)
	}
	if rejected.Load() != 1 || backup.calls.Load() != 1 {
		t.Fatalf("unexpected attempt count: primary %d, backup %d", rejected.Load(), backup.calls.Load())
	}
}

func TestEmbeddingsDimensionMismatchTriesNextSource(t *testing.T) {
	wrong := newEmbedSource(t, 1, 3)
	right := newEmbedSource(t, 2, 4)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "wrong", wrong.URL, "sk-1")
		putProvider(t, c, box, "right", right.URL, "sk-2")
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Dimensions: 4, Routes: []Route{
			{ProviderID: "wrong", UpstreamModel: "m"}, {ProviderID: "right", UpstreamModel: "m", Priority: 1},
		}})
	})
	token := signIn(t, env.authSvc, "ed@b.cn")
	var out embedOut
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "emb", "input": inputs(2)}, &out); code != http.StatusOK || out.Data[0].Embedding[0] != 2 {
		t.Fatalf("维度不符应换来源：%d %+v", code, out)
	}
	if h := env.proxy.router.health.view(healthKey{provider: "wrong", model: "emb", upstream: "m", kind: KindEmbedding}); h.failures != 1 || !strings.Contains(h.lastError, "dimensions") {
		t.Fatalf("维度不符应记为路由失败：%+v", h)
	}
}

func TestEmbeddingsInputValidationAndEstimate(t *testing.T) {
	src := newEmbedSource(t, 1, 4)
	src.noUsage = true
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", src.URL, "sk")
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Routes: []Route{{ProviderID: "p", UpstreamModel: "m"}}})
	})
	token := signIn(t, env.authSvc, "ev@b.cn")
	for _, in := range []any{nil, "", []string{}, []string{"a", ""}, []int{1, 2}, inputs(9)} {
		var p testutil.Problem
		body := map[string]any{"model": "emb"}
		if in != nil {
			body["input"] = in
		}
		if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, body, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
			t.Fatalf("input %v: %d %+v", in, code, p)
		}
	}
	if src.calls.Load() != 0 {
		t.Fatal("不合法的输入不应转发")
	}
	var out embedOut
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "emb", "input": []string{"text-1", "text-22"}}, &out); code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}
	// 来源没有返回 usage：按字数估算 6+7。
	if out.Usage.TotalTokens != 13 {
		t.Fatalf("缺 usage 时按字数估算：%+v", out.Usage)
	}
}

func TestEmbeddingQuotaIsSeparateFromChat(t *testing.T) {
	src := newEmbedSource(t, 1, 4)
	cfg := baseConfig()
	cfg.EmbeddingDailyTokens = 12
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", src.URL, "sk")
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Routes: []Route{{ProviderID: "p", UpstreamModel: "m"}}})
	})
	tokens, _ := env.authSvc.Register(context.Background(), "eq@b.cn", "password1", "")
	token := tokens.AccessToken
	env.quota.SetDailyLimit(tokens.UserID, 1) // 聊天额度很小，不影响嵌入
	body := map[string]any{"model": "emb", "input": inputs(2)}
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, body, nil); code != http.StatusOK {
		t.Fatalf("first: %d", code)
	}
	var p testutil.Problem
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, body, &p); code != http.StatusTooManyRequests || p.Extra["kind"] != "embedding" {
		t.Fatalf("嵌入额度用完应 429：%d %+v", code, p)
	}
	env.quota.SetKindLimit(tokens.UserID, KindEmbedding, 1000)
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, body, nil); code != http.StatusOK {
		t.Fatalf("调高嵌入额度后应通过：%d", code)
	}
}

func TestArrayLen(t *testing.T) {
	for in, want := range map[string]int{`[]`: 0, `[ ]`: 0, `[1]`: 1, `[0.1,-2e-3, 3]`: 3, `"AAAA"`: -1} {
		if got := arrayLen(json.RawMessage(in)); got != want {
			t.Fatalf("%s: got %d want %d", in, got, want)
		}
	}
}

func TestStreamEstimatesWithoutUsage(t *testing.T) {
	var gotPath string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if _, ok := body["stream_options"]; ok {
			t.Errorf("Responses 没有 stream_options，不应转发：%+v", body)
		}
		if body["max_output_tokens"] == nil {
			t.Errorf("没给输出上限时应由服务端补上：%+v", body)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		// 不带 usage：服务端应按字节估算。
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"一二三四五六七八九十\"}\n\n")
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{}}\n\n")
	}))
	defer upstream.Close()
	cfg := baseConfig()
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "up", upstream.URL, "sk")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "m"}}})
	})
	token := signIn(t, env.authSvc, "su@b.cn")
	req := map[string]any{"model": "m", "stream": true, "input": []any{}}
	b, _ := json.Marshal(req)
	body := testutil.ReadBody(t, env.c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(b), nil))
	if !strings.Contains(string(body), "response.completed") {
		t.Fatalf("结束事件应原样转发：%s", body)
	}
	if gotPath != "/responses" {
		t.Fatalf("应转发到来源的 /responses：%s", gotPath)
	}
}

func TestRejectedServerKeyIsNotPassedThrough(t *testing.T) {
	src := newFakeSource(t, "org-secret")
	src.status.Store(http.StatusUnauthorized)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", src.URL, "sk")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{{ProviderID: "p", UpstreamModel: "x"}}})
	})
	token := signIn(t, env.authSvc, "kr@b.cn")
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, strings.NewReader(`{"model":"m","input":[]}`), nil)
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusBadGateway || strings.Contains(string(body), "org-secret") {
		t.Fatalf("key 被拒应返回 502 且不转发提供方的错误体：%d %s", resp.StatusCode, body)
	}
}

func TestEmbeddingsRejectConflictingDimensions(t *testing.T) {
	src := newEmbedSource(t, 1, 4)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", src.URL, "sk")
		putModel(t, c, ModelRecord{Name: "emb", Kind: KindEmbedding, Dimensions: 4, Routes: []Route{{ProviderID: "p", UpstreamModel: "m"}}})
	})
	token := signIn(t, env.authSvc, "dm@b.cn")
	var p testutil.Problem
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "emb", "input": "text-1", "dimensions": 3}, &p); code != http.StatusBadRequest {
		t.Fatalf("与配置不一致的 dimensions 应 400：%d %+v", code, p)
	}
	if src.calls.Load() != 0 {
		t.Fatal("不应转发")
	}
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings", token, map[string]any{"model": "emb", "input": "text-1", "dimensions": 4}, nil); code != http.StatusOK {
		t.Fatalf("一致的 dimensions 可以通过：%d", code)
	}
}

func TestParseEmbedChunkIndexRules(t *testing.T) {
	cases := map[string]bool{
		`{"data":[{"embedding":[1]},{"embedding":[2]}]}`:                         true,  // 全部省略
		`{"data":[{"index":0,"embedding":[1]},{"index":0,"embedding":[2]}]}`:     true,  // 全部为 0
		`{"data":[{"index":1,"embedding":[2]},{"index":0,"embedding":[1]}]}`:     true,  // 乱序但完整
		`{"data":[{"index":1,"embedding":[2]},{"index":1,"embedding":[1]}]}`:     false, // 重复
		`{"data":[{"index":0,"embedding":[1]},{"index":5,"embedding":[2]}]}`:     false, // 越界
		`{"data":[{"index":0,"embedding":[1]},{"index":1,"embedding":null}]}`:    false, // 缺向量
		`{"data":[{"index":0,"embedding":[1,2]},{"index":1,"embedding":[1,2]}]}`: false, // 维度不符
	}
	for body, ok := range cases {
		_, err := parseEmbedChunk([]byte(body), 2, 1)
		if (err == nil) != ok {
			t.Fatalf("%s: ok=%v err=%v", body, ok, err)
		}
	}
}

func newHardeningTestServer(t *testing.T, cfg config.LLMConfig, upstreamURL string) (*testutil.Client, *auth.Service, *MemoryQuota, *Proxy) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	quota := NewMemoryQuota()
	catalog := NewMemoryCatalog()
	ctx := context.Background()
	if err := catalog.PutProvider(ctx, ProviderRecord{ID: "up", Name: "up", BaseURL: upstreamURL, Enabled: true}); err != nil {
		t.Fatal(err)
	}
	putModel(t, catalog, ModelRecord{Name: "deepseek-flash", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "deepseek-flash"}}})
	router := NewRouter(catalog, nil, log)
	if err := router.Reload(ctx); err != nil {
		t.Fatal(err)
	}
	proxy := NewRoutedHandler(cfg, router, quota, time.UTC, log)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{p: proxy},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc, quota, proxy
}

// signIn 注册一个测试账号并返回访问令牌。
type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("请求体不应被读取") }

// TestHandlerConcurrencyLimit 核对同一账号的第 n+1 个在途请求在读取请求体之前
// 被 429 挡下，名额归还之后同一个账号恢复可用。
func TestHandlerConcurrencyLimit(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseAll := func() { releaseOnce.Do(func() { close(release) }) }
	defer releaseAll()

	var forwarded atomic.Int32
	var once sync.Once
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		once.Do(func() { close(entered) })
		<-release
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":5}}`)
	}))
	defer upstream.Close()

	c, authSvc, _, proxy := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:     10000,
		MaxRequestBytes: 1 << 20,
	}, upstream.URL)
	proxy.SetConcurrencyLimit(1)
	token := signIn(t, authSvc, "concurrent@b.cn")
	req := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}

	first := make(chan *http.Response, 1)
	go func() {
		first <- c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(body), map[string]string{"Content-Type": "application/json"})
	}()
	<-entered

	resp := c.Do(http.MethodPost, "/v1/llm/responses", token, failingReader{}, nil)
	problem := testutil.ReadProblem(t, resp)
	if resp.StatusCode != http.StatusTooManyRequests || problem.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("第 2 个在途请求应回 429，得到 %d %+v", resp.StatusCode, problem)
	}
	if got := resp.Header.Get("Retry-After"); got != "1" {
		t.Fatalf("429 应带 Retry-After: 1，得到 %q", got)
	}
	if forwarded.Load() != 1 {
		t.Fatalf("被挡下的请求不应转发上游，上游收到 %d 次", forwarded.Load())
	}

	releaseAll()
	resp1 := <-first
	defer resp1.Body.Close()
	if resp1.StatusCode != http.StatusOK {
		t.Fatalf("放行之后首个请求应成功，得到 %d", resp1.StatusCode)
	}

	// 名额归还之后同一个账号可以继续请求，计数没有残留。
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, req, nil); code != http.StatusOK {
		t.Fatalf("名额归还后应恢复可用，得到 %d", code)
	}
}

// TestHandlerInstanceMemoryBudget 核对实例级字节预算：请求体两倍大小超过预算时在
// 读取之前回 429；请求体进门之后非流式响应占不到响应预算时同样回 429，实例内存
// 因此不再由并发数决定（ADR-0036）。
func TestHandlerInstanceMemoryBudget(t *testing.T) {
	var forwarded atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":5}}`)
	}))
	defer upstream.Close()

	c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:      10000,
		MaxRequestBytes:  1 << 20,
		MaxResponseBytes: 1 << 20,
		MaxInstanceBytes: 4096,
	}, upstream.URL)
	token := signIn(t, authSvc, "budget@b.cn")

	// 正文约 3 KiB，两倍已经超过 4096 字节的预算。
	big, err := json.Marshal(map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": strings.Repeat("x", 3000)}}})
	if err != nil {
		t.Fatal(err)
	}
	resp := c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(big), map[string]string{"Content-Type": "application/json"})
	problem := testutil.ReadProblem(t, resp)
	if resp.StatusCode != http.StatusTooManyRequests || problem.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("超过实例预算应回 429，得到 %d %+v", resp.StatusCode, problem)
	}
	if forwarded.Load() != 0 {
		t.Fatalf("被挡下的请求不应转发，上游收到 %d 次", forwarded.Load())
	}

	// 小请求能进门，但非流式响应上限大于剩余预算，占不到时不写出任何内容。
	small := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}
	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, small, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("响应预算不足应回 429，得到 %d %+v", code, p)
	}
	if forwarded.Load() != 1 {
		t.Fatalf("响应预算不足时上游已经被调用一次，得到 %d", forwarded.Load())
	}
}

// TestHandlerRequiresVerifiedContact 核对没有任何一种已验证登录方式的账号在读取
// 请求体之前被挡下：契约里的 403 contact_unverified 不转发上游，确认之后同一个
// 账号可以继续使用。没有注入检查时按已认证处理，内存装配与现有测试因此不依赖
// 真实账号库。
func TestHandlerRequiresVerifiedContact(t *testing.T) {
	var forwarded atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":10}}`)
	}))
	defer upstream.Close()

	c, authSvc, _, proxy := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:            10000,
		MaxRequestBytes:        1 << 20,
		RequireVerifiedContact: true,
	}, upstream.URL)
	token := signIn(t, authSvc, "unverified@b.cn")
	req := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}

	verified := false
	calls := 0
	proxy.SetContactVerifier(func(_ context.Context, userID string) (bool, error) {
		calls++
		return verified, nil
	})

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, req, &p); code != http.StatusForbidden || p.Code != string(httpx.CodeContactUnverified) {
		t.Fatalf("没有已验证登录方式应回 403 contact_unverified，得到 %d %+v", code, p)
	}
	if forwarded.Load() != 0 {
		t.Fatalf("没有已验证登录方式的请求不应转发上游，上游收到 %d 次", forwarded.Load())
	}
	if calls != 1 {
		t.Fatalf("每次聊天请求应检查一次登录方式确认状态，得到 %d 次", calls)
	}

	verified = true
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, req, nil); code != http.StatusOK {
		t.Fatalf("确认登录方式之后应转发，得到 %d", code)
	}
	if forwarded.Load() != 1 {
		t.Fatalf("确认登录方式之后应转发一次，上游收到 %d 次", forwarded.Load())
	}

	// 没有注入检查时按已认证处理：内存装配与本地开发不接账号库也能用托管额度。
	proxy.SetContactVerifier(nil)
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, req, nil); code != http.StatusOK {
		t.Fatalf("未注入检查时应按已认证处理，得到 %d", code)
	}
	if forwarded.Load() != 2 {
		t.Fatalf("未注入检查时应继续转发，上游收到 %d 次", forwarded.Load())
	}
}

// TestHandlerSettlesActualUsage 核对结算按提供方返回的 usage 记账，而不是按转发
// 前预留的估算值：估算远小于实际用量时额度里记的是实际值；上游错误没有产生用量
// 时预留全部退回。
func TestHandlerSettlesActualUsage(t *testing.T) {
	var calls atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if calls.Add(1) == 1 {
			fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":300}}`)
			return
		}
		// 第二次请求模拟提供方故障：既没有回答，也没有 usage。
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprint(w, `{"error":{"message":"boom"}}`)
	}))
	defer upstream.Close()

	c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:     10000,
		MaxRequestBytes: 1 << 20,
	}, upstream.URL)
	token := signIn(t, authSvc, "settle@b.cn")
	chat := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}

	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusOK {
		t.Fatalf("第一次请求应通过，得到 %d", code)
	}
	var q struct {
		Used int64 `json:"used_tokens"`
	}
	if code := c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q); code != http.StatusOK || q.Used != 300 {
		t.Fatalf("应按实际用量 300 结算，得到 %d %+v", code, q)
	}

	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, nil); code != http.StatusInternalServerError {
		t.Fatalf("上游错误应原样返回，得到 %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q); code != http.StatusOK || q.Used <= 300 {
		t.Fatalf("上游结果不确定时应保留预留，得到 %d %+v", code, q)
	}
}

// TestHandlerQuotaExceededBudget 核对账号额度与实例预算用尽时都回 429
// quota_exceeded：剩余额度不足以覆盖整次预留时拒绝转发；
// 被拒的 extra 保留账号字段，并带上实例用量与预算。
func TestHandlerQuotaExceededBudget(t *testing.T) {
	t.Run("账号额度", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":300}}`)
		}))
		defer upstream.Close()

		c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
			DailyTokens:     10,
			MaxRequestBytes: 1 << 20,
		}, upstream.URL)
		token := signIn(t, authSvc, "budget@b.cn")
		chat := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}

		var p testutil.Problem
		if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeQuotaExceeded) {
			t.Fatalf("额度用完应回 429 quota_exceeded，得到 %d %+v", code, p)
		}
		if got, _ := p.Extra["used_tokens"].(float64); got != 0 {
			t.Fatalf("未转发的请求不应消耗额度，得到 %v", p.Extra)
		}
		if got, _ := p.Extra["daily_tokens"].(float64); got != 10 {
			t.Fatalf("extra 应带账号额度 10，得到 %v", p.Extra)
		}
	})

	t.Run("实例预算", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":20}}`)
		}))
		defer upstream.Close()

		c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
			DailyTokens:         1000,
			InstanceDailyTokens: 20,
			MaxRequestBytes:     1 << 20,
		}, upstream.URL)
		token := signIn(t, authSvc, "instance@b.cn")
		chat := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}

		var p testutil.Problem
		if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeQuotaExceeded) {
			t.Fatalf("实例预算用完应回 429 quota_exceeded，得到 %d %+v", code, p)
		}
		if got, _ := p.Extra["instance_used_tokens"].(float64); got != 0 {
			t.Fatalf("未转发的请求不应消耗实例预算，得到 %v", p.Extra)
		}
		if got, _ := p.Extra["instance_daily_tokens"].(float64); got != 20 {
			t.Fatalf("extra 应带实例预算 20，得到 %v", p.Extra)
		}
	})
}

// TestHandlerRejectsOversizedResponse 核对非流式响应超过上限时回 502
// upstream_failed：此时响应头还没写，客户端拿到的是代理自己的 problem，而不是
// 上游的半截内容。
func TestHandlerRejectsOversizedResponse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":10},"padding":%q}`, strings.Repeat("x", 128))
	}))
	defer upstream.Close()

	c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:      10000,
		MaxRequestBytes:  1 << 20,
		MaxResponseBytes: 64,
	}, upstream.URL)
	token := signIn(t, authSvc, "oversize@b.cn")
	chat := map[string]any{"model": "deepseek-flash", "input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}}}

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/responses", token, chat, &p); code != http.StatusBadGateway || p.Code != string(httpx.CodeUpstreamFailed) {
		t.Fatalf("超限响应应回 502 upstream_failed，得到 %d %+v", code, p)
	}
	if !strings.Contains(p.Detail, "exceeds") {
		t.Fatalf("detail 应说明响应过大，得到 %q", p.Detail)
	}
}

// TestHandlerStreamIdleTimeout 核对流式响应两次数据之间超过空闲时限时中断上游
// 请求并结束响应：已经收到的数据照常交给客户端，连接不会一直挂着。
func TestHandlerStreamIdleTimeout(t *testing.T) {
	canceled := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你\"}\n\n")
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
			close(canceled)
		case <-time.After(5 * time.Second):
			// 代理没有按时中断上游，交给用例在断言处失败。
		}
	}))
	defer upstream.Close()

	c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:       10000,
		MaxRequestBytes:   1 << 20,
		StreamIdleTimeout: 100 * time.Millisecond,
	}, upstream.URL)
	token := signIn(t, authSvc, "idle@b.cn")
	chat := map[string]any{
		"model": "deepseek-flash", "stream": true,
		"input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}},
	}

	start := time.Now()
	body := testutil.ReadBody(t, c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(mustJSON(t, chat)), nil))
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("空闲超时应在时限附近结束响应，实际用了 %v", elapsed)
	}
	if !strings.Contains(string(body), "你") {
		t.Fatalf("超时之前收到的数据应照常转给客户端，得到 %q", body)
	}
	if strings.Contains(string(body), "[DONE]") {
		t.Fatalf("上游没有结束，响应里不应出现结束标记，得到 %q", body)
	}
	select {
	case <-canceled:
	case <-time.After(3 * time.Second):
		t.Fatal("空闲超时应中断上游请求")
	}
}

// TestHandlerStreamTotalTimeout 核对流式响应的总时限：上游一直有数据也会在总
// 时限到达时中断，空闲时限不参与这个判断。
func TestHandlerStreamTotalTimeout(t *testing.T) {
	canceled := make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		ticker := time.NewTicker(10 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-r.Context().Done():
				close(canceled)
				return
			case <-ticker.C:
				fmt.Fprint(w, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"a\"}\n\n")
				flusher.Flush()
			}
		}
	}))
	defer upstream.Close()

	c, authSvc, _, _ := newHardeningTestServer(t, config.LLMConfig{
		DailyTokens:        10000,
		MaxRequestBytes:    1 << 20,
		StreamIdleTimeout:  5 * time.Second,
		StreamTotalTimeout: 150 * time.Millisecond,
	}, upstream.URL)
	token := signIn(t, authSvc, "total@b.cn")
	chat := map[string]any{
		"model": "deepseek-flash", "stream": true,
		"input": []any{map[string]any{"type": "message", "role": "user", "content": "hi"}},
	}

	start := time.Now()
	body := testutil.ReadBody(t, c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(mustJSON(t, chat)), nil))
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("总时限应在时限附近结束响应，实际用了 %v", elapsed)
	}
	if len(body) == 0 {
		t.Fatal("总时限之前收到的数据应照常转给客户端")
	}
	if strings.Contains(string(body), "[DONE]") {
		t.Fatalf("上游没有结束，响应里不应出现结束标记，得到 %q", body)
	}
	select {
	case <-canceled:
	case <-time.After(3 * time.Second):
		t.Fatal("总时限超时应中断上游请求")
	}
}

// mustJSON 把测试请求编码成转发用字节，编码失败直接结束用例。
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
