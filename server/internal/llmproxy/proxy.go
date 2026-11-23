// Package llmproxy forwards model requests to the sources configured by the
// administrator, with server-held keys (ADR-0008, ADR-0029). The only wire
// format is the Responses API (ADR-0052): the client sends its access token as
// the key to <server>/v1/llm/responses. The proxy looks the model name up in
// the routing table, checks the account's daily budget for that kind of model,
// swaps in the source's model name and key, and copies the response through.
// Streams are flushed chunk by chunk; embedding batches are split per route
// and merged back in order. Usage records contain counters; request and
// response bodies are never logged or stored by the proxy.
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
	"strconv"
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

	// verifyContact 判断账号是否至少有一种登录方式已经确认；由 server.New 注入
	// 鉴权得到的 Principal。没有注入时按已认证处理，现有内存装配与测试因此不需要
	// 真实账号也能走通。
	verifyContact func(ctx context.Context, userID string) (bool, error)

	// cache 保存按账号隔离的嵌入向量缓存（ADR-0030），由 server 装配时经
	// SetEmbeddingCache 注入；为空时查找返回空结果、嵌入不写缓存。
	cache EmbeddingCache

	// maxPerUser 是同一账号同时进行的托管请求上限，由 SetConcurrencyLimit 设置，
	// 小于等于 0 表示不限制。inflight 记在途请求数，由 mu 保护；计数归零时删键，
	// map 不随注册过的账号数增长。
	mu         sync.Mutex
	maxPerUser int
	inflight   map[string]int

	// mem 是整个实例同时在途的字节预算（ADR-0036）。账号并发上限只约束单个
	// 账号，账号数量增加时实例总内存仍会跟着涨；请求体、非流式响应与嵌入批次都
	// 从这一份预算里预留，占不到时在读写之前拒绝。
	mem *byteBudget
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
		mem: newByteBudget(cfg.MaxInstanceBytes),
	}
}

// Router 返回代理使用的路由器，管理接口与它共用同一份快照。
func (p *Proxy) Router() *Router { return p.router }

// dayTime 返回配置时区下的当前时间；自然日只从它取，响应里的 date 与用量
// 记录的字符串因此不会落到不同的一天。
func (p *Proxy) dayTime() time.Time { return p.now().In(p.loc) }

func (p *Proxy) day() string { return p.dayTime().Format("2006-01-02") }

// SetContactVerifier 注入“至少一种登录方式已确认”的检查，由 server.New 从鉴权
// 结果里取值：ContactVerified 为真即已确认。没有注入时按已认证处理，保持现有测试
// 与内存装配不需要账号库也能使用托管额度。
func (p *Proxy) SetContactVerifier(fn func(ctx context.Context, userID string) (bool, error)) {
	p.verifyContact = fn
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

// beginRequest 在读请求体之前核对邮箱状态、占用账号的并发名额与实例的内存预算。
// 返回的 done 在请求结束时调用一次，归还并发名额与预算；返回 false 时已经写好
// problem，调用方直接结束。
func (p *Proxy) beginRequest(w http.ResponseWriter, r *http.Request, userID string) (done func(), ok bool) {
	if len(p.router.current().models) == 0 {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "model proxy is not configured on this server")
		return nil, false
	}
	// 登录方式确认在读取请求体之前检查：没有一种确认过的账号拿 403，不消耗请求体
	// 读取、额度预留与上游调用。检查失败按服务端错误处理，不能当成“未确认”放过去。
	if p.cfg.RequireVerifiedContact && p.verifyContact != nil {
		verified, err := p.verifyContact(r.Context(), userID)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return nil, false
		}
		if !verified {
			httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeContactUnverified,
				"verify one of your sign-in identities on the account page to use the hosted model quota")
			return nil, false
		}
	}
	// 并发上限同样在读取请求体之前检查：超出时回 429 与 Retry-After，不占请求体
	// 读取、额度预留与上游连接。名额在请求结束（含流式转发）时由 defer 归还。
	if !p.acquireConcurrency(userID) {
		httpx.TooMany(w, r, 1)
		return nil, false
	}
	// 实例预算按请求体大小预留：读到内存里的正文与替换模型名时重新编码的那一份
	// 各占一份，长度未知（chunked）时按上限算。占不到时同样回 429，账号并发名额
	// 立即归还。
	release, reserved := p.mem.reserve(p.requestBytes(r))
	if !reserved {
		p.releaseConcurrency(userID)
		httpx.TooMany(w, r, 1)
		return nil, false
	}
	return func() {
		release()
		p.releaseConcurrency(userID)
	}, true
}

// requestBytes 是请求体在实例预算里占用的字节数。转发前要把模型名换成来源侧的
// 名字，`withModel` 会按解析后的字段重新编码一份正文，所以预留两倍；声明长度缺失
// 或超过上限时按上限算，客户端不能靠少写 Content-Length 少占预算。
func (p *Proxy) requestBytes(r *http.Request) int64 {
	if p.cfg.MaxRequestBytes <= 0 {
		return 0
	}
	size := r.ContentLength
	if size < 0 || size > p.cfg.MaxRequestBytes {
		size = p.cfg.MaxRequestBytes
	}
	return 2 * size
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

// Responses 转发客户端唯一的对话请求（ADR-0052）。服务端做字段白名单校验、
// 按上限校验或补齐 max_output_tokens、替换模型名并结算额度，事件原样转发；
// 请求体、响应体与流里的用量都不记录。
func (p *Proxy) Responses(w http.ResponseWriter, r *http.Request) {
	userID := auth.MustPrincipal(r.Context()).UserID
	done, ok := p.beginRequest(w, r, userID)
	if !ok {
		return
	}
	defer done()
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
	if raw, ok := fields["input"]; !ok || !isJSONArray(raw) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "input must be a list of input items")
		return
	}
	if raw, ok := fields["instructions"]; ok && !isJSONString(raw) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "instructions must be a string")
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
	output, err := responsesOutputLimit(fields)
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
		if errors.Is(err, errInstanceBusy) {
			httpx.TooMany(w, r, 1)
			return
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

// responsesOutputLimit 检查输出上限；没给时补上 defaultOutputTokens，用量估算
// 要把它算进预留。上限与客户端的 buddyMaxOutputTokens 相同，一端改动要同时改
// 另一端，否则客户端请求会被 400 拒绝（ADR-0053）。
func responsesOutputLimit(fields map[string]json.RawMessage) (int64, error) {
	var output int64
	if raw, ok := fields["max_output_tokens"]; ok {
		if json.Unmarshal(raw, &output) != nil || output < minOutputTokens || output > maxOutputTokens {
			return 0, fmt.Errorf("max_output_tokens must be between %d and %d", minOutputTokens, maxOutputTokens)
		}
	} else {
		output = defaultOutputTokens
		fields["max_output_tokens"] = json.RawMessage(strconv.FormatInt(defaultOutputTokens, 10))
	}
	return output, nil
}

// 对话输出上限的三个数字，单位是 token。客户端按上下文上限的四分之一计算，
// 最高取到 maxOutputTokens；服务端按同一组数字校验，并在客户端省略时补上
// defaultOutputTokens（ADR-0053）。
const (
	minOutputTokens     = 16
	maxOutputTokens     = 32768
	defaultOutputTokens = 4096
)

func isJSONArray(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) > 0 && trimmed[0] == '['
}

func isJSONString(raw json.RawMessage) bool {
	var s string
	return json.Unmarshal(raw, &s) == nil
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

// chatFields 是转发前允许经过的 Responses 请求字段。客户端不发
// `previous_response_id`，服务端也不保存会话；`temperature` 与 `top_p` 仍然
// 放行，供管理端自测与排查使用，客户端不再发送这两个字段。
//
// `store` 放行但取值不由客户端决定：Responses 创建接口默认 `store: true`，
// 上游会把用户内容保存在模型来源一侧。转发前一律改写成 false，见 withModel。
var chatFields = map[string]bool{
	"model": true, "instructions": true, "input": true,
	"max_output_tokens": true, "temperature": true, "top_p": true,
	"stream": true, "tools": true, "tool_choice": true, "parallel_tool_calls": true,
	"reasoning": true, "text": true, "store": true,
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

// withModel 返回转发给来源的请求体：model 换成来源侧名字，`store` 固定写成
// false 并随请求带上，其余字段按原始字节保留。`store` 由服务端决定而不是
// 删掉，因为 Responses 接口在缺少该字段时默认在上游保存响应。
func withModel(fields map[string]json.RawMessage, upstream string) ([]byte, error) {
	out := make(map[string]json.RawMessage, len(fields)+1)
	for k, v := range fields {
		out[k] = v
	}
	name, err := json.Marshal(upstream)
	if err != nil {
		return nil, err
	}
	out["model"] = name
	out["store"] = json.RawMessage("false")
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
		resp, err := p.attempt(ctx, rt.Provider, upstreamResponsesPath, body, stream)
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
		mediaType, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type"))
		// 来源回一份页面或 problem+json 错误时，换下一个来源：网关的故障页与
		// 来源自己的错误体都不是客户端的对话响应，照抄给客户端只会让调用方按
		// 格式错误结束。流式请求另有下面的流式类型检查，这里只管整段响应。
		if !stream && (mediaType == "text/html" || mediaType == "application/problem+json") {
			resp.Body.Close()
			finish(attemptResult{tokens: -1})
			p.router.health.fail(rt.ProviderID, "响应类型不可用")
			lastErr = errors.New("provider did not return a usable response")
			continue
		}
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
		// 非流式响应要整段读进内存再写回客户端：先按上限从实例预算里预留，
		// 占不到时没有写出任何内容，整次请求按实例繁忙结束，不换来源重试。
		release, reserved := p.mem.reserve(p.cfg.MaxResponseBytes)
		if !reserved {
			resp.Body.Close()
			finish(attemptResult{tokens: -1})
			return reply, errInstanceBusy
		}
		b, err := readResponse(resp.Body, p.cfg.MaxResponseBytes)
		resp.Body.Close()
		release()
		if err == nil && !isResponsesBody(b) {
			err = errors.New("invalid response object")
		}
		used := usageTokens(b, KindChat)
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

// upstreamResponsesPath 是来源侧接收对话请求的路径。来源都是 OpenAI 兼容地址，
// 以 /v1 结尾；管理员在后台配置来源时写的就是这个结尾。
const upstreamResponsesPath = "/responses"

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
	if headerDeadline {
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

// usageEnvelope 读 Responses 与 Embeddings 两种响应里的用量：对话是
// input_tokens、output_tokens 与 total_tokens，嵌入是 prompt_tokens 与
// total_tokens，两种都认，取值以实际出现的字段为准。
type usageEnvelope struct {
	Usage *struct {
		InputTokens      int64 `json:"input_tokens"`
		OutputTokens     int64 `json:"output_tokens"`
		PromptTokens     int64 `json:"prompt_tokens"`
		TotalTokens      int64 `json:"total_tokens"`
		CompletionTokens int64 `json:"completion_tokens"`
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
	// 客户端每个请求都发 store: false，Responses 的用量只随响应出现一次；
	// 没有 total_tokens 时按输入与输出相加。
	if u.Usage.InputTokens > 0 || u.Usage.OutputTokens > 0 {
		return u.Usage.InputTokens + u.Usage.OutputTokens
	}
	return 0
}

// isResponsesBody 检查整段响应是不是一个 Response 对象：非流式请求必须给出
// 对象形状，否则换下一个来源。
func isResponsesBody(b []byte) bool {
	var env struct {
		ID     string                       `json:"id"`
		Object string                       `json:"object"`
		Output []map[string]json.RawMessage `json:"output"`
	}
	if json.Unmarshal(b, &env) != nil {
		return false
	}
	return env.Output != nil || env.Object == "response" || env.ID != ""
}

// errResponseTooLarge 表示非流式响应超过配置的上限。发现时还没有写响应头，调用
// 方可以按 upstream_failed 回 problem，而不是把半截响应交给客户端。
var errResponseTooLarge = errors.New("llmproxy: 上游响应过大")

// errInstanceBusy 表示实例的在途字节预算已经用完。发现时还没有写出任何响应内容，
// 调用方按 429 回 problem，客户端稍后重试；这里不排队等待，托管请求本身可能持续
// 几分钟，排队只是把内存压力换成 goroutine 积压。
var errInstanceBusy = errors.New("llmproxy: 实例在途内存预算已用完")

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
// boundary), and picks the last usage object it sees. A terminal response event
// distinguishes an upstream completion from a dropped connection.
func (p *Proxy) copyStream(w http.ResponseWriter, body io.Reader) (result attemptResult, clientWriteFailed bool) {
	flusher, _ := w.(http.Flusher)
	rd := bufio.NewReaderSize(body, 64*1024)
	result.tokens = -1
	var done bool
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			trimmed := bytes.TrimRight(line, "\r\n")
			if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
				data = bytes.TrimSpace(data)
				done = done || terminalEvent(data)
				var envelope struct {
					usageEnvelope
					Response *usageEnvelope `json:"response"`
				}
				if bytes.Contains(data, []byte(`"usage"`)) && json.Unmarshal(data, &envelope) == nil {
					used := envelope.tokens(KindChat)
					if envelope.Response != nil {
						if inner := envelope.Response.tokens(KindChat); inner > 0 {
							used = inner
						}
					}
					if used > 0 {
						result.tokens = used
					}
				}
			}
			if _, werr := w.Write(line); werr != nil {
				return result, true
			}
			if len(trimmed) == 0 && flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			if flusher != nil {
				flusher.Flush()
			}
			result.success = done && errors.Is(err, io.EOF)
			return result, false
		}
	}
}

// terminalEvent 报告一个流式负载是不是结束事件：Responses 的成功、失败与未完成
// 都算，数据里没写 type 时按 OpenAI 的 [DONE] 收尾。
func terminalEvent(data []byte) bool {
	if bytes.Equal(data, []byte("[DONE]")) {
		return true
	}
	if !bytes.Contains(data, []byte(`"type"`)) {
		return false
	}
	var event struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(data, &event) != nil {
		return false
	}
	switch event.Type {
	case "response.completed", "response.incomplete", "response.failed":
		return true
	}
	return false
}
