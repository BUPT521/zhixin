// Package llmproxy forwards OpenAI-compatible requests to the model sources
// configured by the administrator, with server-held keys (ADR-0008, ADR-0029).
//
// The client keeps its existing Chat Completions and Embeddings request
// builders: it points the base URL at <server>/v1/llm and sends its access
// token as the key. The proxy looks the model name up in the routing table,
// checks the account's daily budget for that kind of model, swaps in the
// source's model name and key, and copies the response through. Chat streams
// are flushed chunk by chunk; embedding batches are split per route and merged
// back in order. Usage records contain counters; request and response bodies
// are never logged or stored by the proxy.
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
	"mime"
	"net"
	"net/http"
	"sync"
	"time"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

type Proxy struct {
	cfg          config.LLMConfig
	router       *Router
	quota        Quota
	usage        UsageStore
	client       *http.Client
	publicClient *http.Client
	loc          *time.Location
	now          func() time.Time
	log          *slog.Logger

	// verifyEmail 判断账号是否已经确认邮箱；由 server.New 注入账号库的 UserByID。
	// 没有注入时按已认证处理，现有内存装配与测试因此不需要真实账号也能走通。
	verifyEmail func(ctx context.Context, userID string) (bool, error)

	// cache 保存按账号隔离的嵌入向量缓存（ADR-0030），由 server 装配时经
	// SetEmbeddingCache 注入；为空时查找返回空结果、嵌入不写缓存。cacheGate 是
	// 清除云端数据的闸门，闸门返回错误时不写缓存。
	cache     EmbeddingCache
	cacheGate func(ctx context.Context, userID string) error

	// maxPerUser 是同一账号同时进行的托管请求上限，由 SetConcurrencyLimit 设置，
	// 小于等于 0 表示不限制。inflight 记在途请求数，由 mu 保护；计数归零时删键，
	// map 不随注册过的账号数增长。
	mu         sync.Mutex
	maxPerUser int
	inflight   map[string]int
}

// NewRoutedHandler 使用服务端从数据库读出的路由快照。
func NewRoutedHandler(cfg config.LLMConfig, router *Router, quota Quota, loc *time.Location, log *slog.Logger) *Proxy {
	if setter, ok := quota.(quotaLimits); ok {
		setter.SetQuotaLimits(cfg.DailyTokens, cfg.EmbeddingDailyTokens, cfg.InstanceDailyTokens)
	}

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
	noRedirect := func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	var publicClient *http.Client
	if cfg.RestrictProviders {
		publicTransport := transport.Clone()
		publicTransport.Proxy = nil
		publicTransport.DialContext = dialPublicProvider
		publicClient = &http.Client{Transport: publicTransport, CheckRedirect: noRedirect}
	}
	return &Proxy{
		cfg: cfg, router: router, quota: quota,
		// 不跟随重定向：同主机从 https 跳到 http 时标准库会带着 Authorization
		// 再发一次，key 会以明文出现在网络上。来源的地址应当直接写对。
		client: &http.Client{Transport: transport, CheckRedirect: noRedirect}, publicClient: publicClient,
		loc: loc, now: time.Now, log: log, inflight: map[string]int{},
	}
}

// Router 返回代理使用的路由器，管理接口与它共用同一份快照。
func (p *Proxy) Router() *Router { return p.router }

// dayTime 返回配置时区下的当前时间；自然日只从它取，响应里的 date 与用量
// 记录的字符串因此不会落到不同的一天。
func (p *Proxy) dayTime() time.Time { return p.now().In(p.loc) }

func (p *Proxy) day() string { return p.dayTime().Format("2006-01-02") }

// SetEmailVerifier 注入邮箱确认检查，由 server.New 用账号库的 UserByID 实现：
// EmailVerifiedAt 非零即已确认。没有注入时按已认证处理，保持现有测试与内存装配
// 不需要账号库也能使用托管额度。
func (p *Proxy) SetEmailVerifier(fn func(ctx context.Context, userID string) (bool, error)) {
	p.verifyEmail = fn
}

// SetConcurrencyLimit 设置同一账号同时进行的托管请求上限，由 server.New 按
// ZHIXIN_LLM_CONCURRENT_PER_USER 注入；小于等于 0 表示不限制。
func (p *Proxy) SetConcurrencyLimit(n int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.maxPerUser = n
}

// acquireConcurrency 给账号占一个并发名额；达到上限时返回 false。名额在请求
// 结束时由 defer 归还，上游失败、超时与客户端断开都不例外。
func (p *Proxy) acquireConcurrency(userID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.maxPerUser <= 0 {
		return true
	}
	if p.inflight[userID] >= p.maxPerUser {
		return false
	}
	p.inflight[userID]++
	return true
}

// releaseConcurrency 归还并发名额；计数归零时删除键，长时间运行也不会留下空项。
func (p *Proxy) releaseConcurrency(userID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.maxPerUser <= 0 {
		return
	}
	p.inflight[userID]--
	if p.inflight[userID] <= 0 {
		delete(p.inflight, userID)
	}
}

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

// beginRequest 在读请求体之前核对邮箱状态并占用账号的并发名额。
func (p *Proxy) beginRequest(w http.ResponseWriter, r *http.Request, userID string) bool {
	if len(p.router.current().models) == 0 {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "model proxy is not configured on this server")
		return false
	}
	// 邮箱确认在读取请求体之前检查：未确认的账号拿 403，不消耗请求体读取、额度
	// 预留与上游调用。检查失败按服务端错误处理，不能当成“未确认”放过去。
	if p.cfg.RequireVerifiedEmail && p.verifyEmail != nil {
		verified, err := p.verifyEmail(r.Context(), userID)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return false
		}
		if !verified {
			httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeEmailUnverified,
				"verify your email address on the account page to use the hosted model quota")
			return false
		}
	}
	// 并发上限同样在读取请求体之前检查：超出时回 429 与 Retry-After，不占请求体
	// 读取、额度预留与上游连接。名额在请求结束（含流式转发）时由 defer 归还。
	if !p.acquireConcurrency(userID) {
		httpx.TooMany(w, r, 1)
		return false
	}
	return true
}

// findModel 解析当前快照中的同用途模型；失败时写入 problem。
func (p *Proxy) findModel(w http.ResponseWriter, r *http.Request, fields map[string]json.RawMessage, kind Kind) *liveModel {
	snap := p.router.current()
	if len(snap.models) == 0 {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "model proxy is not configured on this server")
		return nil
	}
	var name string
	_ = json.Unmarshal(fields["model"], &name)
	m, ok := snap.model(name)
	if !ok || m.Kind != kind || !m.usable() {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeModelNotAllowed, "", map[string]any{"models": snap.modelNames(kind)})
		return nil
	}
	return m
}

type attemptResult struct {
	// A negative token count keeps the reservation when usage is unknown.
	tokens, estimated int64
	success           bool
}

type finishAttempt func(attemptResult)

// attemptBudget reserves quota and supplies a completion function for a route.
// A nil budget is used for admin probes.
type attemptBudget func(liveRoute, int64) (finishAttempt, error)

func (budget attemptBudget) start(route liveRoute, estimate int64) (finishAttempt, error) {
	if budget == nil {
		return func(attemptResult) {}, nil
	}
	return budget(route, estimate)
}

type quotaReservationError struct{ cause error }

func (e quotaReservationError) Error() string { return e.cause.Error() }
func (e quotaReservationError) Unwrap() error { return e.cause }

func (p *Proxy) budget(r *http.Request, userID, day string, model *liveModel) attemptBudget {
	return func(route liveRoute, estimate int64) (finishAttempt, error) {
		reserved, err := p.quota.Reserve(r.Context(), userID, day, model.Kind, estimate)
		if err != nil {
			return nil, quotaReservationError{cause: err}
		}
		if reserved < estimate {
			p.settle(r, userID, day, model.Kind, reserved, 0)
			return nil, ErrQuotaExceeded
		}
		return func(result attemptResult) {
			if result.tokens < 0 {
				result.tokens, result.estimated = reserved, reserved
			}
			p.settle(r, userID, day, model.Kind, reserved, result.tokens)
			if p.usage != nil {
				p.recordRouteUsage(r.Context(), RouteUsage{
					Day: day,
					RouteUsageKey: RouteUsageKey{
						Kind: model.Kind, Model: model.Name, ProviderID: route.ProviderID, UpstreamModel: route.UpstreamModel,
					},
					UsageCounts: UsageCounts{
						Attempts: 1, Tokens: result.tokens, EstimatedTokens: result.estimated,
					},
				}, result.success)
			}
		}, nil
	}
}

func (p *Proxy) recordRouteUsage(ctx context.Context, row RouteUsage, success bool) {
	if success {
		row.Successes = 1
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := p.usage.AddRouteUsage(ctx, row); err != nil {
		p.log.Error("record llm route usage", slog.String("request_id", httpx.RequestIDFrom(ctx)), slog.String("error", err.Error()))
	}
}

// settle 即使客户端断开也结算本次预留。
func (p *Proxy) settle(r *http.Request, userID, day string, kind Kind, reserved, actual int64) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	if err := p.quota.Settle(ctx, userID, day, kind, reserved, actual); err != nil {
		p.log.Error("settle llm usage", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	}
}

func (p *Proxy) Chat(w http.ResponseWriter, r *http.Request) {
	userID := auth.MustPrincipal(r.Context()).UserID
	if !p.beginRequest(w, r, userID) {
		return
	}
	defer p.releaseConcurrency(userID)
	fields, ok := p.readBody(w, r)
	if !ok {
		return
	}
	model := p.findModel(w, r, fields, KindChat)
	if model == nil {
		return
	}
	if !allowFields(w, r, fields, chatFields) {
		return
	}
	if raw, ok := fields["tools"]; ok && !functionToolsOnly(raw) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "tools must be a list of functions")
		return
	}
	var stream bool
	if raw, ok := fields["stream"]; ok {
		if err := json.Unmarshal(raw, &stream); err != nil {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "stream must be a boolean")
			return
		}
	}
	if stream {
		fields["stream_options"] = json.RawMessage(`{"include_usage":true}`)
	} else {
		delete(fields, "stream_options")
	}
	output, err := chatOutputLimit(fields)
	if err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}
	day := p.day()
	reserve := p.budget(r, userID, day, model)

	// 流式响应套一层守卫：总时限从发起上游请求时开始，空闲时限从收到响应体之后
	// 开始；超时取消上游请求，阻塞中的读取随即返回。非流式沿用请求自身的 context。
	reqCtx := r.Context()
	var guard *streamGuard
	if stream {
		reqCtx, guard = p.newStreamGuard(reqCtx)
		defer guard.stop()
	} else if p.cfg.StreamTotalTimeout > 0 {
		var cancel context.CancelFunc
		reqCtx, cancel = context.WithTimeout(reqCtx, p.cfg.StreamTotalTimeout)
		defer cancel()
	}
	reply, err := p.dispatch(reqCtx, p.router.candidates(model, p.cfg.MaxAttempts), fields, stream, output, reserve)
	if err != nil {
		if r.Context().Err() != nil {
			return // client went away
		}
		if errors.Is(err, ErrQuotaExceeded) {
			p.writeQuotaExceeded(w, r, userID, day, KindChat)
			return
		}
		var budgetError quotaReservationError
		if errors.As(err, &budgetError) {
			httpx.WriteInternal(w, r, p.log, err)
			return
		}
		detail := "could not get a valid response from any model source"
		if errors.Is(err, errResponseTooLarge) {
			detail = fmt.Sprintf("provider response exceeds %d bytes", p.cfg.MaxResponseBytes)
		}
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, detail)
		return
	}
	if reply.status < 200 || reply.status >= 300 {
		writeUpstreamStatus(w, r, reply.status)
		return
	}
	if !stream {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(reply.status)
		_, _ = w.Write(reply.body)
		return
	}

	defer reply.stream.Close()
	guard.watch(reply.stream, p.cfg.StreamIdleTimeout)
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(reply.status)
	var body io.Reader = guard
	if p.cfg.MaxResponseBytes > 0 {
		body = io.LimitReader(body, p.cfg.MaxResponseBytes)
	}
	result, clientWriteFailed := p.copyStream(w, body)
	if result.success {
		p.router.health.succeed(reply.route.ProviderID)
	} else if r.Context().Err() == nil && !clientWriteFailed {
		p.router.health.fail(reply.route.ProviderID, "流式响应提前结束")
	}
	reply.finish(result)
}

// chatOutputLimit accepts the two OpenAI-compatible names for the same limit.
func chatOutputLimit(fields map[string]json.RawMessage) (int64, error) {
	if raw, ok := fields["n"]; ok && string(raw) != "1" {
		return 0, errors.New("n must be 1")
	}
	key := "max_tokens"
	if _, ok := fields["max_completion_tokens"]; ok {
		if _, duplicate := fields[key]; duplicate {
			return 0, errors.New("only one completion token limit may be set")
		}
		key = "max_completion_tokens"
	}
	const defaultOutput = 1024
	const maxOutput = 8192
	var output int64
	if raw, ok := fields[key]; ok {
		if json.Unmarshal(raw, &output) != nil || output < 1 || output > maxOutput {
			return 0, fmt.Errorf("%s must be between 1 and %d", key, maxOutput)
		}
	} else {
		output = defaultOutput
		fields[key] = json.RawMessage("1024")
	}
	return output, nil
}

func rejectedUsage(status int) int64 {
	switch status {
	case 400, 401, 403, 404, 413, 422, 429:
		return 0
	default:
		return -1
	}
}

func writeUpstreamStatus(w http.ResponseWriter, r *http.Request, status int) {
	if keyRejected(status) || status < 400 {
		status = http.StatusBadGateway
	}
	httpx.WriteProblem(w, r, status, httpx.CodeUpstreamFailed, "model source could not complete the request")
}

// keyRejected 表示最后一个来源拒绝了服务端的 key。这是服务端的配置问题，
// 提供方的错误体里可能带着打码的 key、组织名与来源侧模型名，不转给客户端。
func keyRejected(status int) bool {
	return status == http.StatusUnauthorized || status == http.StatusForbidden
}

var chatFields = map[string]bool{
	"model": true, "messages": true, "max_tokens": true, "max_completion_tokens": true,
	"n": true, "stream": true, "stream_options": true, "temperature": true,
	"top_p": true, "stop": true, "presence_penalty": true, "frequency_penalty": true,
	"tools": true, "tool_choice": true, "parallel_tool_calls": true,
	"thinking": true, "reasoning_effort": true, "response_format": true,
}

func functionToolsOnly(raw json.RawMessage) bool {
	var tools []struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(raw, &tools) != nil || tools == nil {
		return false
	}
	for _, tool := range tools {
		if tool.Type != "function" {
			return false
		}
	}
	return true
}

func allowFields(w http.ResponseWriter, r *http.Request, fields map[string]json.RawMessage, allowed map[string]bool) bool {
	for name := range fields {
		if !allowed[name] {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "unsupported model request field")
			return false
		}
	}
	return true
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

type chatReply struct {
	route  liveRoute
	status int
	body   []byte
	stream io.ReadCloser
	finish finishAttempt
}

// dispatch tries the next candidate while a response can still be replaced.
// For a stream, ownership of its body and its settlement moves to Chat.
func (p *Proxy) dispatch(ctx context.Context, cands []liveRoute, fields map[string]json.RawMessage, stream bool, output int64, reserve attemptBudget) (chatReply, error) {
	var lastErr error = errors.New("no usable route")
	var reply chatReply
	for i, rt := range cands {
		reply = chatReply{route: rt}
		body, err := withModel(fields, rt.UpstreamModel)
		if err != nil {
			return reply, err
		}
		finish, err := reserve.start(rt, int64(len(body))+output)
		if err != nil {
			return reply, err
		}
		resp, err := p.attempt(ctx, rt.Provider, "/chat/completions", body, stream)
		if err != nil {
			finish(attemptResult{tokens: -1})
			if ctx.Err() != nil {
				return reply, ctx.Err()
			}
			p.router.health.fail(rt.ProviderID, "无法连接模型来源")
			lastErr = err
			continue
		}
		reply.status = resp.StatusCode
		if reply.status < 200 || reply.status >= 300 {
			resp.Body.Close()
			finish(attemptResult{tokens: rejectedUsage(reply.status)})
			if retryable(reply.status) {
				p.router.health.fail(rt.ProviderID, fmt.Sprintf("HTTP %d", reply.status))
				if i < len(cands)-1 {
					continue
				}
			}
			return reply, nil
		}
		if stream {
			mediaType, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type"))
			if mediaType == "application/json" || mediaType == "text/html" || mediaType == "application/problem+json" {
				resp.Body.Close()
				finish(attemptResult{tokens: -1})
				p.router.health.fail(rt.ProviderID, "流式响应类型不可用")
				lastErr = errors.New("provider did not return a chat stream")
				continue
			}
			reply.stream, reply.finish = resp.Body, finish
			return reply, nil
		}
		b, err := readResponse(resp.Body, p.cfg.MaxResponseBytes)
		resp.Body.Close()
		var completion struct {
			usageEnvelope
			Choices []struct {
				Message map[string]json.RawMessage `json:"message"`
			} `json:"choices"`
		}
		if err == nil && (json.Unmarshal(b, &completion) != nil || len(completion.Choices) == 0 ||
			len(completion.Choices[0].Message) == 0) {
			err = errors.New("invalid chat completion")
		}
		used := completion.tokens(KindChat)
		if used <= 0 {
			used = -1
		}
		if err != nil {
			finish(attemptResult{tokens: used})
			if ctx.Err() != nil {
				return reply, ctx.Err()
			}
			p.router.health.fail(rt.ProviderID, "聊天响应不可用")
			lastErr = err
			continue
		}
		finish(attemptResult{tokens: used, success: true})
		p.router.health.succeed(rt.ProviderID)
		reply.body = b
		return reply, nil
	}
	return reply, lastErr
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
	resp, err := p.sendToProvider(req, prov)
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

// writeQuotaExceeded 回 429 quota_exceeded，并带上当天的账号用量、账号额度与
// 实例预算：客户端据此提示额度用完，响应里也能看出是哪一种额度用尽。
func (p *Proxy) writeQuotaExceeded(w http.ResponseWriter, r *http.Request, userID, day string, kind Kind) {
	used, err := p.quota.Used(r.Context(), userID, day, kind)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	limit, err := p.dailyLimit(r.Context(), userID, kind)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	instanceUsed, err := p.quota.InstanceUsed(r.Context(), day)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	httpx.WriteProblemExtra(w, r, http.StatusTooManyRequests, httpx.CodeQuotaExceeded,
		"daily budget used up; use your own key or try again tomorrow",
		map[string]any{
			"day":                   day,
			"kind":                  string(kind),
			"used_tokens":           used,
			"daily_tokens":          limit,
			"instance_used_tokens":  instanceUsed,
			"instance_daily_tokens": p.cfg.InstanceDailyTokens,
		})
}

type usageEnvelope struct {
	Usage *struct {
		PromptTokens     int64  `json:"prompt_tokens"`
		TotalTokens      int64  `json:"total_tokens"`
		CompletionTokens *int64 `json:"completion_tokens"`
	} `json:"usage"`
}

func (u usageEnvelope) tokens(kind Kind) int64 {
	if u.Usage == nil {
		return 0
	}
	if u.Usage.TotalTokens > 0 {
		return u.Usage.TotalTokens
	}
	if kind == KindEmbedding {
		return u.Usage.PromptTokens
	}
	if u.Usage.CompletionTokens != nil && *u.Usage.CompletionTokens >= 0 {
		return u.Usage.PromptTokens + *u.Usage.CompletionTokens
	}
	return 0
}

// errResponseTooLarge 表示非流式响应超过配置的上限。发现时还没有写响应头，调用
// 方可以按 upstream_failed 回 problem，而不是把半截响应交给客户端。
var errResponseTooLarge = errors.New("llmproxy: 上游响应过大")

// readResponse 最多读 maxBytes；maxBytes 非正表示不限制。超限时返回
// errResponseTooLarge，不返回部分内容。
func readResponse(body io.Reader, maxBytes int64) ([]byte, error) {
	if maxBytes <= 0 {
		return io.ReadAll(body)
	}
	b, err := io.ReadAll(io.LimitReader(body, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > maxBytes {
		return nil, errResponseTooLarge
	}
	return b, nil
}

// copyResponseHeaders 只复制客户端解释响应需要的头；其余头由代理自己决定。
// usageTokens 从非流式响应体里取可以结算的用量。
func usageTokens(b []byte, kind Kind) int64 {
	var env usageEnvelope
	if json.Unmarshal(b, &env) == nil {
		return env.tokens(kind)
	}
	return 0
}

// streamGuard 在流式转发期间守住空闲与总时限。总时限从发起上游请求时开始，空闲
// 时限在两次读到数据之间计时；任一超时都取消上游请求，阻塞中的 Read 返回错误，
// 响应到此结束。不用 http.Client.Timeout，因为它只能给整次请求一个硬时限，分不
// 出空闲与总量，也无法在响应头已经写出之后换成 problem 响应。
type streamGuard struct {
	body        io.Reader
	cancel      context.CancelFunc
	idleTimeout time.Duration
	idle        *time.Timer
	total       *time.Timer
}

// newStreamGuard 创建可取消的上游 context 与守卫；总时限立即开始计时。
func (p *Proxy) newStreamGuard(ctx context.Context) (context.Context, *streamGuard) {
	ctx, cancel := context.WithCancel(ctx)
	guard := &streamGuard{cancel: cancel}
	if p.cfg.StreamTotalTimeout > 0 {
		guard.total = time.AfterFunc(p.cfg.StreamTotalTimeout, cancel)
	}
	return ctx, guard
}

// watch 绑定上游响应体并开始空闲计时；之后每次读到数据由 Read 重置计时器。
func (g *streamGuard) watch(body io.Reader, idleTimeout time.Duration) {
	g.body = body
	g.idleTimeout = idleTimeout
	if idleTimeout > 0 {
		g.idle = time.AfterFunc(idleTimeout, g.cancel)
	}
}

func (g *streamGuard) Read(b []byte) (int, error) {
	n, err := g.body.Read(b)
	if n > 0 && g.idle != nil {
		g.idle.Reset(g.idleTimeout)
	}
	return n, err
}

// stop 在转发结束时停掉计时器并取消 context；响应已经结束，取消不再影响客户端。
func (g *streamGuard) stop() {
	if g.idle != nil {
		g.idle.Stop()
	}
	if g.total != nil {
		g.total.Stop()
	}
	g.cancel()
}

// copyStream forwards SSE line by line, flushing at each blank line (event
// boundary), and picks the last usage object it sees. An explicit completion
// marker distinguishes an upstream completion from a dropped connection.
func (p *Proxy) copyStream(w http.ResponseWriter, body io.Reader) (result attemptResult, clientWriteFailed bool) {
	flusher, _ := w.(http.Flusher)
	rd := bufio.NewReaderSize(body, 64*1024)
	result.tokens = -1
	var done, finishReason, completeChoice bool
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			trimmed := bytes.TrimRight(line, "\r\n")
			if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
				data = bytes.TrimSpace(data)
				done = done || bytes.Equal(data, []byte("[DONE]"))
				var chunk struct {
					usageEnvelope
					Choices []struct {
						FinishReason string `json:"finish_reason"`
					} `json:"choices"`
				}
				if (bytes.Contains(data, []byte(`"usage"`)) || bytes.Contains(data, []byte(`"finish_reason"`))) &&
					json.Unmarshal(data, &chunk) == nil {
					if used := chunk.tokens(KindChat); used > 0 {
						result.tokens = used
					}
					finishReason = finishReason || (len(chunk.Choices) > 0 && chunk.Choices[0].FinishReason != "")
				}
			}
			if _, werr := w.Write(line); werr != nil {
				return result, true
			}
			if len(trimmed) == 0 && flusher != nil {
				flusher.Flush()
			}
			if len(trimmed) == 0 {
				result.success = done
				completeChoice = finishReason
			}
		}
		if err != nil {
			if flusher != nil {
				flusher.Flush()
			}
			result.success = result.success || (errors.Is(err, io.EOF) && completeChoice)
			return result, false
		}
	}
}
