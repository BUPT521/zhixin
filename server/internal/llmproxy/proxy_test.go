package llmproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
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

// newTestServer 装配本包处理器与鉴权中间件，返回客户端与用于签发测试令牌的
// 账号服务。
func newTestServer(t *testing.T, cfg config.LLMConfig) (*testutil.Client, *auth.Service) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	proxy := New(cfg, NewMemoryQuota(), time.UTC, log)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{p: proxy},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc
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

	c, authSvc := newTestServer(t, config.LLMConfig{
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

func TestHandlerLLMProxyDisabledWithoutKey(t *testing.T) {
	c, authSvc := newTestServer(t, config.LLMConfig{
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
