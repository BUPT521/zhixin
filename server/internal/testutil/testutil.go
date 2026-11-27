// Package testutil 是各包处理器测试共用的 HTTP 辅助：直接调用 http.Handler，
// 不经真实端口，并把 JSON 与 problem 响应的编解码收在一处。
package testutil

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Client 在进程内把请求交给一个 http.Handler。
type Client struct {
	t       *testing.T
	handler http.Handler
}

// NewClient 用已装配好的 handler 建客户端。
func NewClient(t *testing.T, handler http.Handler) *Client {
	t.Helper()
	return &Client{t: t, handler: handler}
}

// Do 发一次请求并返回响应；token 非空时作为 Bearer 令牌，headers 逐条设置。
func (c *Client) Do(method, path, token string, body io.Reader, headers map[string]string) *http.Response {
	c.t.Helper()
	req := httptest.NewRequest(method, path, body)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	c.handler.ServeHTTP(rec, req)
	return rec.Result()
}

// JSON 发一次 JSON 请求并返回状态码；in 非空时编码为请求体，out 非空时解码响应体。
func (c *Client) JSON(method, path, token string, in, out any) int {
	c.t.Helper()
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			c.t.Fatalf("%s %s: marshal: %v", method, path, err)
		}
		body = bytes.NewReader(b)
	}
	resp := c.Do(method, path, token, body, map[string]string{"Content-Type": "application/json"})
	defer resp.Body.Close()
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil && err != io.EOF {
			c.t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return resp.StatusCode
}

// Problem 是 application/problem+json 的测试视图。
type Problem struct {
	Status    int            `json:"status"`
	Code      string         `json:"code"`
	RequestID string         `json:"request_id"`
	Detail    string         `json:"detail"`
	Extra     map[string]any `json:"extra"`
}

// ReadProblem 解码 problem 响应体，读完即关闭。
func ReadProblem(t *testing.T, resp *http.Response) Problem {
	t.Helper()
	defer resp.Body.Close()
	var p Problem
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decode problem: %v", err)
	}
	return p
}

// ReadBody 读取并关闭响应体。
func ReadBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return b
}

// NewServer 按生产装配的顺序搭一个 handler：中间件交给生成代码，套在每条已匹配
// 路由的内部，运行时 r.Pattern 已经由 mux 写好，鉴权据此判定；request_id 与统一
// 响应头放在最外层，和 server.Build 的链一致。SecurityHeaders 必须在链上：它换上的
// cacheGuard 夹在 RecordPattern 与访问日志之间，route 记录靠它转交（S19）。
func NewServer(si api.ServerInterface, mw ...api.MiddlewareFunc) http.Handler {
	mux := http.NewServeMux()
	handler := api.HandlerWithOptions(si, api.StdHTTPServerOptions{
		BaseRouter:       mux,
		Middlewares:      mw,
		ErrorHandlerFunc: httpx.BindingErrorHandler,
	})
	return httpx.Chain(handler, httpx.RequestID, httpx.SecurityHeaders)
}

// Base 让用例只实现自己用到的路由。嵌入的接口为零值，没有覆盖到的路由被调用
// 时会 panic，提示补桩；契约新增接口时不需要改这个文件。
type Base struct{ api.ServerInterface }
