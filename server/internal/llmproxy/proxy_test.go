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

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	p *Proxy
}

func (a testAPI) GetV1LlmModels(w http.ResponseWriter, r *http.Request) { a.p.Models(w, r) }
func (a testAPI) GetV1LlmQuota(w http.ResponseWriter, r *http.Request)  { a.p.QuotaStatus(w, r) }

func (a testAPI) PostV1LlmChatCompletions(w http.ResponseWriter, r *http.Request) {
	a.p.Chat(w, r)
}

// newTestServer 装配本包处理器与鉴权中间件，返回客户端、账号服务、内存额度与
// 代理本身，便于用例调整个别账号的额度或注入邮箱确认检查。
func newTestServer(t *testing.T, cfg config.LLMConfig) (*testutil.Client, *auth.Service, *MemoryQuota, *Proxy) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	quota := NewMemoryQuota()
	proxy := NewHandler(cfg, quota, time.UTC, log)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{p: proxy},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc, quota, proxy
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

// failingReader 模拟一个一读就失败的请求体：并发上限在读取请求体之前生效，所以
// 被挡下的请求应拿到 429 而不是 400，这个读取器同时守住检查顺序。
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
		fmt.Fprint(w, `{"choices":[],"usage":{"total_tokens":5}}`)
	}))
	defer upstream.Close()

	c, authSvc, _, proxy := newTestServer(t, config.LLMConfig{
		BaseURL:         upstream.URL,
		APIKey:          "sk-server",
		Models:          []string{"deepseek-flash"},
		DailyTokens:     1000,
		MaxRequestBytes: 1 << 20,
	})
	proxy.SetConcurrencyLimit(1)
	token := signIn(t, authSvc, "concurrent@b.cn")
	req := map[string]any{"model": "deepseek-flash", "messages": []any{map[string]string{"role": "user", "content": "hi"}}}
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}

	first := make(chan *http.Response, 1)
	go func() {
		first <- c.Do(http.MethodPost, "/v1/llm/chat/completions", token, bytes.NewReader(body), map[string]string{"Content-Type": "application/json"})
	}()
	<-entered

	resp := c.Do(http.MethodPost, "/v1/llm/chat/completions", token, failingReader{}, nil)
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
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, req, nil); code != http.StatusOK {
		t.Fatalf("名额归还后应恢复可用，得到 %d", code)
	}
}

// TestHandlerRequiresVerifiedEmail 核对未确认邮箱的账号在读取请求体之前被挡下：
// 契约里的 403 email_unverified 不转发上游，确认之后同一个账号可以继续使用。
// 没有注入检查时按已认证处理，内存装配与现有测试因此不依赖真实账号库。
func TestHandlerRequiresVerifiedEmail(t *testing.T) {
	var forwarded atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwarded.Add(1)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"choices":[],"usage":{"total_tokens":10}}`)
	}))
	defer upstream.Close()

	c, authSvc, _, proxy := newTestServer(t, config.LLMConfig{
		BaseURL:              upstream.URL,
		APIKey:               "sk-server",
		Models:               []string{"deepseek-flash"},
		DailyTokens:          1000,
		MaxRequestBytes:      1 << 20,
		RequireVerifiedEmail: true,
	})
	token := signIn(t, authSvc, "unverified@b.cn")
	req := map[string]any{"model": "deepseek-flash", "messages": []any{map[string]string{"role": "user", "content": "hi"}}}

	verified := false
	calls := 0
	proxy.SetEmailVerifier(func(_ context.Context, userID string) (bool, error) {
		calls++
		return verified, nil
	})

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, req, &p); code != http.StatusForbidden || p.Code != string(httpx.CodeEmailUnverified) {
		t.Fatalf("未确认邮箱应回 403 email_unverified，得到 %d %+v", code, p)
	}
	if forwarded.Load() != 0 {
		t.Fatalf("未确认邮箱的请求不应转发上游，上游收到 %d 次", forwarded.Load())
	}
	if calls != 1 {
		t.Fatalf("每次聊天请求应检查一次邮箱确认状态，得到 %d 次", calls)
	}

	verified = true
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, req, nil); code != http.StatusOK {
		t.Fatalf("确认邮箱之后应转发，得到 %d", code)
	}
	if forwarded.Load() != 1 {
		t.Fatalf("确认邮箱之后应转发一次，上游收到 %d 次", forwarded.Load())
	}

	// 没有注入检查时按已认证处理：内存装配与本地开发不接账号库也能用托管额度。
	proxy.SetEmailVerifier(nil)
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, req, nil); code != http.StatusOK {
		t.Fatalf("未注入检查时应按已认证处理，得到 %d", code)
	}
	if forwarded.Load() != 2 {
		t.Fatalf("未注入检查时应继续转发，上游收到 %d 次", forwarded.Load())
	}
}

func TestHandlerLLMProxy(t *testing.T) {
	var gotAuth string
	var gotBody map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n")
		w.(http.Flusher).Flush()
		fmt.Fprint(w, "data: {\"choices\":[],\"usage\":{\"total_tokens\":120}}\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	c, authSvc, _, _ := newTestServer(t, config.LLMConfig{
		BaseURL:         upstream.URL,
		APIKey:          "sk-server",
		Models:          []string{"deepseek-flash"},
		DailyTokens:     100,
		MaxRequestBytes: 1 << 20,
	})
	token := signIn(t, authSvc, "a@b.cn")

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, map[string]any{"model": "gpt-x"}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeModelNotAllowed) {
		t.Fatalf("model check: %d %+v", code, p)
	}

	req := map[string]any{"model": "deepseek-flash", "stream": true, "messages": []any{map[string]string{"role": "user", "content": "hi"}}}
	b, _ := json.Marshal(req)
	stream := testutil.ReadBody(t, c.Do(http.MethodPost, "/v1/llm/chat/completions", token, bytes.NewReader(b), nil))
	if !strings.Contains(string(stream), "你") || !strings.HasSuffix(string(stream), "data: [DONE]\n\n") {
		t.Fatalf("stream: %q", stream)
	}
	if gotAuth != "Bearer sk-server" {
		t.Fatalf("upstream auth = %q; the client token must not be forwarded", gotAuth)
	}
	if gotBody["model"] != "deepseek-flash" {
		t.Fatalf("body not forwarded: %+v", gotBody)
	}

	var q struct {
		Used int64 `json:"used_tokens"`
	}
	if code := c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q); code != http.StatusOK || q.Used != 120 {
		t.Fatalf("usage: %d %+v", code, q)
	}
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, req, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeQuotaExceeded) {
		t.Fatalf("quota: %d %+v", code, p)
	}
}

func TestHandlerQuotaOverride(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[],\"usage\":{\"total_tokens\":120}}\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	c, authSvc, quota, _ := newTestServer(t, config.LLMConfig{
		BaseURL:         upstream.URL,
		APIKey:          "sk-server",
		Models:          []string{"deepseek-flash"},
		DailyTokens:     100,
		MaxRequestBytes: 1 << 20,
	})
	tokens, err := authSvc.Register(context.Background(), "override@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	token := tokens.AccessToken
	chat := map[string]any{
		"model": "deepseek-flash", "stream": true,
		"messages": []any{map[string]string{"role": "user", "content": "hi"}},
	}

	// 默认额度 100：第一次花掉 120，第二次按默认额度会被拒。
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, chat, nil); code != http.StatusOK {
		t.Fatalf("第一次请求应通过，得到 %d", code)
	}
	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, chat, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeQuotaExceeded) {
		t.Fatalf("默认额度应用完：%d %+v", code, p)
	}

	// 调高这个账号之后，同样的用量不再被拒。
	quota.SetDailyLimit(tokens.UserID, 5000)
	var q struct {
		Used        int64 `json:"used_tokens"`
		DailyTokens int64 `json:"daily_tokens"`
	}
	if code := c.JSON(http.MethodGet, "/v1/llm/quota", token, nil, &q); code != http.StatusOK || q.DailyTokens != 5000 || q.Used != 120 {
		t.Fatalf("额度接口应返回调整后的值：%d %+v", code, q)
	}
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, chat, nil); code != http.StatusOK {
		t.Fatalf("调整之后应通过，得到 %d", code)
	}

	// 调低之后立即生效，被拒时 extra 里带的是调整后的额度。
	quota.SetDailyLimit(tokens.UserID, 100)
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, chat, &p); code != http.StatusTooManyRequests {
		t.Fatalf("调低之后应被拒，得到 %d", code)
	}
	if got, _ := p.Extra["daily_tokens"].(float64); got != 100 {
		t.Fatalf("被拒的额度应为调整后的 100，得到 %v", p.Extra)
	}
}

func TestHandlerLLMProxyDisabledWithoutKey(t *testing.T) {
	c, authSvc, _, _ := newTestServer(t, config.LLMConfig{
		BaseURL:         "http://127.0.0.1:1",
		Models:          []string{"deepseek-flash"},
		DailyTokens:     100,
		MaxRequestBytes: 1 << 20,
	})
	token := signIn(t, authSvc, "a@b.cn")

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/llm/chat/completions", token, map[string]any{"model": "deepseek-flash"}, &p); code != http.StatusServiceUnavailable || p.Code != string(httpx.CodeUnavailable) {
		t.Fatalf("got %d %+v", code, p)
	}
}
