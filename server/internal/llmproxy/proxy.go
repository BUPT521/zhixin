// Package llmproxy forwards OpenAI-compatible requests to the model sources
// configured by the administrator, with server-held keys (ADR-0008, ADR-0028).
//
// The client keeps its existing Chat Completions and Embeddings request
// builders: it points the base URL at <server>/v1/llm and sends its access
// token as the key. The proxy looks the model name up in the routing table,
// checks the account's daily budget for that kind of model, swaps in the
// source's model name and key, and copies the response through. Chat streams
// are flushed chunk by chunk; embedding batches are split per route and merged
// back in order. Request and response bodies are never logged or stored; only
// the token count from the provider's "usage" object is recorded.
package llmproxy

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"time"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

type Proxy struct {
	cfg    config.LLMConfig
	router *Router
	quota  Quota
	client *http.Client
	loc    *time.Location
	now    func() time.Time
	log    *slog.Logger
}

// EnvSourceFrom 取出配置里的环境变量来源。
func EnvSourceFrom(cfg config.LLMConfig) EnvSource {
	return EnvSource{
		BaseURL:         cfg.BaseURL,
		APIKey:          cfg.APIKey,
		ChatModels:      cfg.Models,
		EmbeddingModels: cfg.EmbeddingModels,
	}
}

// NewHandler 组装模型代理；构造函数与另外几个业务包同名。
func NewHandler(cfg config.LLMConfig, router *Router, quota Quota, loc *time.Location, log *slog.Logger) *Proxy {
	// No overall client timeout: chat streams legitimately last minutes. The
	// client's own per-event deadlines (docs/00 §9) cancel the request, which
	// cancels r.Context() and with it the upstream call. Streams and
	// embeddings get a response-header deadline per attempt (see attempt).
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ForceAttemptHTTP2:     true,
		MaxIdleConnsPerHost:   16,
		IdleConnTimeout:       90 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
	return &Proxy{
		cfg: cfg, router: router, quota: quota,
		// 不跟随重定向：同主机从 https 跳到 http 时标准库会带着 Authorization
		// 再发一次，key 会以明文出现在网络上。来源的地址应当直接写对。
		client: &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		}},
		loc: loc, now: time.Now, log: log,
	}
}

// Router 返回代理使用的路由器，管理接口与它共用同一份快照。
func (p *Proxy) Router() *Router { return p.router }

// dayTime 返回配置时区下的当前时间；自然日只从它取，响应里的 date 与用量
// 记录的字符串因此不会落到不同的一天。
func (p *Proxy) dayTime() time.Time { return p.now().In(p.loc) }

func (p *Proxy) day() string { return p.dayTime().Format("2006-01-02") }

// Models answers in the OpenAI list shape so the client's connection test
// works unchanged; kind and dimensions tell chat and embedding models apart.
func (p *Proxy) Models(w http.ResponseWriter, r *http.Request) {
	snap := p.router.current()
	data := make([]api.Model, 0, len(snap.models))
	for _, m := range snap.models {
		if !m.usable() {
			continue
		}
		item := api.Model{Id: m.Name, Object: "model", OwnedBy: "zhixin", Kind: api.ModelKind(m.Kind)}
		if m.Kind == KindEmbedding && m.Dimensions > 0 {
			d := m.Dimensions
			item.Dimensions = &d
		}
		data = append(data, item)
	}
	httpx.WriteJSON(w, http.StatusOK, api.ModelList{Object: "list", Data: data})
}

func (p *Proxy) QuotaStatus(w http.ResponseWriter, r *http.Request) {
	pr := auth.MustPrincipal(r.Context())
	day := p.day()
	out := api.LLMQuota{Day: openapi_types.Date{Time: p.dayTime()}}
	for _, k := range []Kind{KindChat, KindEmbedding} {
		used, err := p.quota.Used(r.Context(), pr.UserID, day, k)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return
		}
		limit, err := p.dailyLimit(r.Context(), pr.UserID, k)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return
		}
		if k == KindChat {
			out.UsedTokens, out.DailyTokens = used, limit
		} else {
			out.EmbeddingUsedTokens, out.EmbeddingDailyTokens = used, limit
		}
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// dailyLimit 返回账号当天某类模型可用的 token 上限：先看有没有按账号调整过的
// 额度，没有时用配置的默认值。调整写 llm_quota 表，不重启服务，下一次请求生效。
func (p *Proxy) dailyLimit(ctx context.Context, userID string, kind Kind) (int64, error) {
	limit, ok, err := p.quota.DailyLimit(ctx, userID, kind)
	if err != nil {
		return 0, err
	}
	if ok {
		return limit, nil
	}
	if kind == KindEmbedding {
		return p.cfg.EmbeddingDailyTokens, nil
	}
	return p.cfg.DailyTokens, nil
}

// readBody 读入请求体并解成顶层字段；失败时已经写好 problem。
func (p *Proxy) readBody(w http.ResponseWriter, r *http.Request) (map[string]json.RawMessage, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, p.cfg.MaxRequestBytes))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, fmt.Sprintf("request exceeds %d bytes", p.cfg.MaxRequestBytes))
			return nil, false
		}
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "could not read body")
		return nil, false
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil || fields == nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "body is not a JSON object")
		return nil, false
	}
	return fields, true
}

// admit 找到模型并检查当天额度；失败时已经写好 problem。
func (p *Proxy) admit(w http.ResponseWriter, r *http.Request, fields map[string]json.RawMessage, kind Kind) (*liveModel, string, bool) {
	pr := auth.MustPrincipal(r.Context())
	snap := p.router.current()
	if len(snap.models) == 0 {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "model proxy is not configured on this server")
		return nil, "", false
	}
	var name string
	_ = json.Unmarshal(fields["model"], &name)
	m, ok := snap.model(name)
	if !ok || m.Kind != kind || !m.usable() {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeModelNotAllowed, "", map[string]any{"models": snap.modelNames(kind)})
		return nil, "", false
	}
	day := p.day()
	used, err := p.quota.Used(r.Context(), pr.UserID, day, kind)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return nil, "", false
	}
	limit, err := p.dailyLimit(r.Context(), pr.UserID, kind)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return nil, "", false
	}
	if used >= limit {
		httpx.WriteProblemExtra(w, r, http.StatusTooManyRequests, httpx.CodeQuotaExceeded,
			"daily budget used up; use your own key or try again tomorrow",
			map[string]any{"day": day, "kind": string(kind), "used_tokens": used, "daily_tokens": limit})
		return nil, "", false
	}
	return m, day, true
}

// record 记录用量。用新的 context：客户端可能在最后一块之后就断开了，但
// token 已经花掉。
func (p *Proxy) record(r *http.Request, day string, kind Kind, tokens int64) {
	if tokens <= 0 {
		return
	}
	pr := auth.MustPrincipal(r.Context())
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	if err := p.quota.Add(ctx, pr.UserID, day, kind, tokens); err != nil {
		p.log.Error("record llm usage", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	}
}

func (p *Proxy) Chat(w http.ResponseWriter, r *http.Request) {
	fields, ok := p.readBody(w, r)
	if !ok {
		return
	}
	m, day, ok := p.admit(w, r, fields, KindChat)
	if !ok {
		return
	}
	var stream bool
	_ = json.Unmarshal(fields["stream"], &stream)
	if stream {
		// 用量只能从 usage 读到：流式请求一律要求提供方在最后一块带上 usage，
		// 客户端省略 stream_options 也不能让这次请求不计额度。
		fields["stream_options"] = withIncludeUsage(fields["stream_options"])
	}

	resp, _, err := p.dispatch(r.Context(), p.router.candidates(m, p.cfg.MaxAttempts), "/chat/completions", fields, stream)
	if err != nil {
		if r.Context().Err() != nil {
			return // client went away
		}
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, "could not reach any model source")
		return
	}
	defer resp.Body.Close()
	if keyRejected(resp.StatusCode) {
		drain(resp)
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, "the model sources rejected the server key")
		return
	}

	// Pass the provider's status and body through, including errors: the
	// client already reads provider error bodies to explain key, quota and
	// model-name problems (app/README §模型).
	for _, h := range []string{"Content-Type", "Cache-Control"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)

	var tokens, forwarded int64
	if stream {
		tokens, forwarded = copyStream(w, resp.Body)
	} else {
		tokens, forwarded = copyWhole(w, resp.Body)
	}
	if tokens == 0 && resp.StatusCode < 300 {
		// 提供方没有给 usage，或者客户端在最后一块之前断开：按请求与已转发的
		// 字节估算，中文大约三个字节一个 token。宁可多记，也不让这次请求免费。
		var reqBytes int64
		for _, v := range fields {
			reqBytes += int64(len(v))
		}
		tokens = (reqBytes + forwarded) / 3
	}
	p.record(r, day, KindChat, tokens)
}

// keyRejected 表示最后一个来源拒绝了服务端的 key。这是服务端的配置问题，
// 提供方的错误体里可能带着打码的 key、组织名与来源侧模型名，不转给客户端。
func keyRejected(status int) bool {
	return status == http.StatusUnauthorized || status == http.StatusForbidden
}

// withIncludeUsage 在 stream_options 里打开 include_usage，保留客户端的其他字段。
func withIncludeUsage(raw json.RawMessage) json.RawMessage {
	opts := map[string]json.RawMessage{}
	_ = json.Unmarshal(raw, &opts)
	if opts == nil {
		opts = map[string]json.RawMessage{}
	}
	opts["include_usage"] = json.RawMessage("true")
	out, _ := json.Marshal(opts)
	return out
}

// retryable 报告这个状态码是否换下一个来源再试：限流、服务端错误与 key 被拒
// 都可能只是这个来源的问题；400、404、422 这类说明请求本身有问题，换来源也
// 一样，直接返回给客户端。
func retryable(status int) bool {
	return status == http.StatusUnauthorized || status == http.StatusForbidden ||
		status == http.StatusRequestTimeout || status == http.StatusTooManyRequests ||
		status >= 500
}

// withModel 返回把 model 换成来源侧名字之后的请求体。其余字段按原始字节保留。
func withModel(fields map[string]json.RawMessage, upstream string) ([]byte, error) {
	out := make(map[string]json.RawMessage, len(fields))
	for k, v := range fields {
		out[k] = v
	}
	name, err := json.Marshal(upstream)
	if err != nil {
		return nil, err
	}
	out["model"] = name
	return json.Marshal(out)
}

// dispatch 按候选顺序尝试，直到某个来源给出不需要换来源的响应。所有来源都
// 连不上时返回错误；最后一个来源返回可重试状态时把它的响应原样交给调用方。
func (p *Proxy) dispatch(ctx context.Context, cands []liveRoute, path string, fields map[string]json.RawMessage, stream bool) (*http.Response, liveRoute, error) {
	var lastErr error = errors.New("no usable route")
	for i, rt := range cands {
		body, err := withModel(fields, rt.UpstreamModel)
		if err != nil {
			return nil, rt, err
		}
		resp, err := p.attempt(ctx, rt.Provider, path, body, stream || path != "/chat/completions")
		if err != nil {
			if ctx.Err() != nil {
				return nil, rt, ctx.Err()
			}
			p.router.health.fail(rt.Provider.ID, "连接失败："+err.Error())
			lastErr = err
			continue
		}
		if retryable(resp.StatusCode) {
			p.router.health.fail(rt.Provider.ID, fmt.Sprintf("HTTP %d", resp.StatusCode))
			if i < len(cands)-1 {
				drain(resp)
				continue
			}
			return resp, rt, nil
		}
		if resp.StatusCode < 400 {
			p.router.health.succeed(rt.Provider.ID)
		}
		return resp, rt, nil
	}
	return nil, liveRoute{}, lastErr
}

// attempt 向一个来源发一次请求。headerDeadline 为真时，响应头必须在
// HeaderTimeout 内到达，否则按连接失败处理，便于换下一个来源；非流式聊天
// 要等整段回答生成完才有响应头，不设这个期限。
func (p *Proxy) attempt(ctx context.Context, prov *liveProvider, path string, body []byte, headerDeadline bool) (*http.Response, error) {
	actx, cancel := context.WithCancel(ctx)
	req, err := http.NewRequestWithContext(actx, http.MethodPost, prov.BaseURL+path, bytes.NewReader(body))
	if err != nil {
		cancel()
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if prov.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+prov.APIKey)
	}
	if path == "/chat/completions" && headerDeadline {
		req.Header.Set("Accept", "text/event-stream")
	}
	var timer *time.Timer
	if headerDeadline && p.cfg.HeaderTimeout > 0 {
		timer = time.AfterFunc(p.cfg.HeaderTimeout, cancel)
	}
	resp, err := p.client.Do(req)
	if timer != nil && !timer.Stop() {
		// 期限在 Do 返回前后到点：响应体已经被取消，当作超时。
		if err == nil {
			resp.Body.Close()
		}
		cancel()
		return nil, fmt.Errorf("no response within %s", p.cfg.HeaderTimeout)
	}
	if err != nil {
		cancel()
		return nil, err
	}
	resp.Body = cancelOnClose{ReadCloser: resp.Body, cancel: cancel}
	return resp, nil
}

type cancelOnClose struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c cancelOnClose) Close() error {
	err := c.ReadCloser.Close()
	c.cancel()
	return err
}

// drain 读掉一小段响应体再关闭，让连接可以复用。
func drain(resp *http.Response) {
	_, _ = io.CopyN(io.Discard, resp.Body, 64<<10)
	resp.Body.Close()
}

type usageEnvelope struct {
	Usage *struct {
		PromptTokens int64 `json:"prompt_tokens"`
		TotalTokens  int64 `json:"total_tokens"`
	} `json:"usage"`
}

func (u usageEnvelope) tokens() int64 {
	if u.Usage == nil {
		return 0
	}
	if u.Usage.TotalTokens > 0 {
		return u.Usage.TotalTokens
	}
	return u.Usage.PromptTokens
}

// copyWhole 转发整段响应，返回 usage 里的 token 数与转发的字节数。
func copyWhole(w http.ResponseWriter, body io.Reader) (int64, int64) {
	b, err := io.ReadAll(body)
	_, _ = w.Write(b)
	if err != nil {
		return 0, int64(len(b))
	}
	var env usageEnvelope
	if json.Unmarshal(b, &env) == nil {
		return env.tokens(), int64(len(b))
	}
	return 0, int64(len(b))
}

// copyStream forwards SSE line by line, flushing at each blank line (event
// boundary), and picks the last usage object it sees. It also returns the
// number of bytes forwarded, for the estimate when no usage arrives.
func copyStream(w http.ResponseWriter, body io.Reader) (tokens, forwarded int64) {
	flusher, _ := w.(http.Flusher)
	rd := bufio.NewReaderSize(body, 64*1024)
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			forwarded += int64(len(line))
			if _, werr := w.Write(line); werr != nil {
				return tokens, forwarded
			}
			trimmed := bytes.TrimRight(line, "\r\n")
			if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
				data = bytes.TrimSpace(data)
				var env usageEnvelope
				if bytes.Contains(data, []byte(`"usage"`)) && json.Unmarshal(data, &env) == nil && env.tokens() > 0 {
					tokens = env.tokens()
				}
			}
			if len(trimmed) == 0 && flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			if flusher != nil {
				flusher.Flush()
			}
			return tokens, forwarded
		}
	}
}
