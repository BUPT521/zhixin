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

// NewServer 用生成的契约路由组装 handler：Base 没被覆盖的路由回 404，参数绑定
// 失败走与服务端相同的 problem 响应。中间件按给出的顺序由外到内套上。
func NewServer(si api.ServerInterface, mw ...func(http.Handler) http.Handler) http.Handler {
	mux := http.NewServeMux()
	handler := api.HandlerWithOptions(si, api.StdHTTPServerOptions{
		BaseRouter:       mux,
		ErrorHandlerFunc: httpx.BindingErrorHandler,
	})
	return httpx.Chain(handler, mw...)
}

// Base 实现 api.ServerInterface，所有方法回 404。用例把它嵌进自己的实现，只
// 覆盖本包的路由；契约新增接口时这里编译失败，提醒补上桩。
type Base struct{}

func (Base) GetHealthz(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }
func (Base) GetReadyz(w http.ResponseWriter, _ *http.Request)  { w.WriteHeader(http.StatusNotFound) }
func (Base) DeleteV1Cloud(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) DeleteV1Me(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }
func (Base) GetV1Me(w http.ResponseWriter, _ *http.Request)    { w.WriteHeader(http.StatusNotFound) }
func (Base) PostV1AuthLogin(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthLogout(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthRefresh(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthRegister(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthEmailVerifyRequest(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthEmailVerifyConfirm(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthPasswordForgot(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1AuthPasswordReset(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) GetV1Backups(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }

func (Base) DeleteV1Backups(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) PostV1Backups(w http.ResponseWriter, _ *http.Request, _ api.PostV1BackupsParams) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) DeleteV1BackupsId(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) GetV1BackupsId(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) GetV1BlobsSha256(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) HeadV1BlobsSha256(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) PutV1BlobsSha256(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) PostV1LlmChatCompletions(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1LlmEmbeddings(w http.ResponseWriter, _ *http.Request, _ api.PostV1LlmEmbeddingsParams) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostV1LlmEmbeddingsLookup(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) GetAdminV1Providers(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PutAdminV1ProvidersId(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) DeleteAdminV1ProvidersId(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostAdminV1ProvidersIdTest(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) GetAdminV1Models(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) GetAdminV1Usage(w http.ResponseWriter, _ *http.Request, _ api.GetAdminV1UsageParams) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PutAdminV1ModelsName(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) DeleteAdminV1ModelsName(w http.ResponseWriter, _ *http.Request, _ string) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) PostAdminV1ModelsNameTest(w http.ResponseWriter, _ *http.Request, _ string, _ api.PostAdminV1ModelsNameTestParams) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) GetV1LlmModels(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
func (Base) GetV1LlmQuota(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }
func (Base) GetV1SyncHead(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }

func (Base) DeleteV1SyncCommits(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) GetV1SyncCommits(w http.ResponseWriter, _ *http.Request, _ api.GetV1SyncCommitsParams) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) PostV1SyncCommits(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) GetV1AppReleases(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) PostV1Feedback(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}

func (Base) PostV1TelemetryActive(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusNotFound)
}
