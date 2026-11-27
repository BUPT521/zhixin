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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/http/httptrace"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	points       Points
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
	// 小于等于 0 表示不限制。inflight 记在途请求数，background 记其中可以等的
	// 后台请求数，两者由 mu 保护；计数归零时删键，map 不随注册过的账号数增长。
	mu         sync.Mutex
	maxPerUser int
	inflight   map[string]int
	background map[string]int

	// mem 是整个实例同时在途的字节预算（ADR-0036）。账号并发上限只约束单个
	// 账号，账号数量增加时实例总内存仍会跟着涨；请求体、非流式响应与嵌入批次都
	// 从这一份预算里预留，占不到时在读写之前拒绝。
	mem *byteBudget
}

// NewRoutedHandler 使用服务端从数据库读出的路由快照。quota 负责预留与结算，
// points 负责账号页的积分视图；两种能力由装配处按消费方分别注入。
func NewRoutedHandler(cfg config.LLMConfig, router *Router, quota Quota, points Points, loc *time.Location, log *slog.Logger) *Proxy {
	if setter, ok := quota.(quotaLimits); ok {
		setter.SetQuotaLimits(cfg.DailyTokens, cfg.InstanceDailyTokens)
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
		cfg: cfg, router: router, quota: quota, points: points,
		// 不跟随重定向：同主机从 https 跳到 http 时标准库会带着 Authorization
		// 再发一次，key 会以明文出现在网络上。来源的地址应当直接写对。
		client: &http.Client{Transport: transport, CheckRedirect: noRedirect}, publicClient: publicClient,
		loc: loc, now: time.Now, log: log, inflight: map[string]int{}, background: map[string]int{},
		mem: newByteBudget(cfg.MaxInstanceBytes).withBackgroundShare(cfg.BackgroundInstancePercent),
	}
}

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
// 结束时由 defer 归还，上游失败、超时与客户端断开都不例外。background 表示材料
// 导入与索引补算这类可以等的请求，它们只能占用没有留给前台的名额，前台请求因此
// 不会被后台批次挤掉。
func (p *Proxy) acquireConcurrency(userID string, background bool) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.maxPerUser <= 0 {
		return true
	}
	if p.inflight[userID] >= p.maxPerUser {
		return false
	}
	if background && p.background[userID] >= p.backgroundLimit() {
		return false
	}
	p.inflight[userID]++
	if background {
		p.background[userID]++
	}
	return true
}

// backgroundLimit 是同一账号可以同时进行的后台请求数：并发上限减去给前台保留
// 的名额，至少留一个，避免保留名额把后台完全挡住。
func (p *Proxy) backgroundLimit() int {
	if p.maxPerUser <= 0 {
		return 0
	}
	return max(p.maxPerUser-p.cfg.ForegroundReserved, 1)
}

// releaseConcurrency 归还并发名额；计数归零时删除键，长时间运行也不会留下空项。
func (p *Proxy) releaseConcurrency(userID string, background bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.maxPerUser <= 0 {
		return
	}
	p.inflight[userID]--
	if p.inflight[userID] <= 0 {
		delete(p.inflight, userID)
	}
	if background {
		p.background[userID]--
		if p.background[userID] <= 0 {
			delete(p.background, userID)
		}
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
	// 比例只有配置一处来源，由 config.Load 校验为正数；这里不再兜底，避免两处
	// 默认值各自变化之后客户端换算与核销对不上。
	out := api.LLMQuota{
		Day:            openapi_types.Date{Time: p.dayTime()},
		TokensPerPoint: p.cfg.TokensPerPoint,
	}
	for _, k := range []Kind{KindChat, KindEmbedding} {
		used, err := p.quota.Used(r.Context(), pr.UserID, day, k)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return
		}
		out.UsedTokens += used
		if k == KindEmbedding {
			out.EmbeddingUsedTokens = used
		}
	}
	limit, err := p.dailyLimit(r.Context(), pr.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	out.DailyTokens = limit
	// 积分只在开通收款的实例上有：当天已核销多少、副本里还剩多少，账号页按这两个
	// 数写“免费额度用完之后今天用了多少、还剩多少”（ADR-0069）。两个字段各按自己
	// 的数据是否可用决定返回与否：副本缺失时已核销积分照常返回，不跟着一起变 null。
	points, err := p.points.Points(r.Context(), pr.UserID, day)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	if points.ChargedKnown {
		charged := points.Charged
		out.ChargedPoints = &charged
	}
	if points.RemainingKnown {
		remaining := points.Remaining
		out.RemainingPoints = &remaining
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// dailyLimit 返回账号当天共用的免费计费 token 上限：先看有没有按账号调整过的
// 额度，没有时用配置的默认值。调整写 llm_quota 表，不重启服务，下一次请求生效。
func (p *Proxy) dailyLimit(ctx context.Context, userID string) (int64, error) {
	limit, ok, err := p.quota.DailyLimit(ctx, userID)
	if err != nil {
		return 0, err
	}
	if ok {
		return limit, nil
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
// background 表示材料导入与索引补算这类可以等的请求，它们只能使用没有留给前台
// 的并发名额与内存。返回的 done 在请求结束时调用一次，归还并发名额与预算；返回
// false 时已经写好 problem，调用方直接结束。
func (p *Proxy) beginRequest(w http.ResponseWriter, r *http.Request, userID string, background bool) (done func(), ok bool) {
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
	if !p.acquireConcurrency(userID, background) {
		httpx.TooMany(w, r, 1)
		return nil, false
	}
	// 实例预算按请求体大小预留：读到内存里的正文与替换模型名时重新编码的那一份
	// 各占一份，长度未知（chunked）时按上限算。占不到时同样回 429，账号并发名额
	// 立即归还。
	release, reserved := p.mem.reserveWorkload(p.requestBytes(r), background)
	if !reserved {
		p.releaseConcurrency(userID, background)
		httpx.TooMany(w, r, 1)
		return nil, false
	}
	return func() {
		release()
		p.releaseConcurrency(userID, background)
	}, true
}

// requestBytes 是请求体在实例预算里占用的字节数。转发前要把模型名换成来源侧的
// 名字，转发前会按解析后的字段重新编码一份正文，所以预留两倍；声明长度缺失
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

// RequestOptions 是请求头里与调度有关的选项，由路由层从契约参数转进来。
type RequestOptions struct {
	// RoundBudgetMs 是客户端带来的本轮剩余预算，单位毫秒，见 roundDeadline。
	RoundBudgetMs *int64
	// SessionID 是客户端为一条讨论生成的稳定标识，见 sessionKey。
	SessionID *string
}

// Responses 转发客户端唯一的对话请求（ADR-0052）。服务端做字段白名单校验、
// 按上限校验或补齐 max_output_tokens、替换模型名并结算额度，事件原样转发；
// 请求体、响应体与流里的用量都不记录。本轮预算与讨论标识随 opts 传入，前者
// 约束整段回答、空闲等待与首字等待，后者让同一讨论的追问落到同一条来源。
func (p *Proxy) Responses(w http.ResponseWriter, r *http.Request, opts RequestOptions) {
	principal := auth.MustPrincipal(r.Context())
	userID := principal.UserID
	// 用接入密钥调用的是用户自己的脚本与第三方工具，请求形状不受我们控制，
	// 按放宽的口径处理：不认识的字段删掉、超出范围的上限截断，不让整次请求
	// 因为一个用不上的参数失败。知新客户端用访问令牌，仍按 ADR-0052 的字段与
	// 上限严格校验（ADR-0063 的密钥就是给这些工具用的）。
	lenient := principal.KeyID != ""
	done, ok := p.beginRequest(w, r, userID, false)
	if !ok {
		return
	}
	defer done()
	deadline := p.roundDeadline(opts.RoundBudgetMs)
	fields, ok := p.readBody(w, r)
	if !ok {
		return
	}
	model := p.findModel(w, r, fields, KindChat)
	if model == nil {
		return
	}
	if lenient {
		normalizeClientResponses(fields)
	}
	if !allowFields(w, r, fields, lenient, chatFields, clientHintFields) {
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
	output, err := responsesOutputLimit(fields, lenient)
	if err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}
	day := p.day()
	reserve := p.budget(r, userID, day, model)

	// 流式响应套一层守卫：总时限从发起上游请求时开始，空闲时限从收到响应体之后
	// 开始；超时取消上游请求，阻塞中的读取随即返回。非流式沿用请求自身的 context
	// 加一份整段时限。两种时限都不超过本轮剩余预算。
	if !deadline.IsZero() && !p.now().Before(deadline) {
		writeRoundExpired(w, r)
		return
	}
	reqCtx := r.Context()
	var guard *streamGuard
	if stream {
		reqCtx, guard = p.newStreamGuard(reqCtx, deadline)
		defer guard.stop()
	} else if total := p.responseTimeout(deadline); total > 0 {
		var cancel context.CancelFunc
		reqCtx, cancel = context.WithTimeout(reqCtx, total)
		defer cancel()
	}
	// 请求要用的能力先核对：带图片或 tools 时只走管理员核对过对应能力的路由，
	// 一条都没有时直接说明缺哪一种，不让请求发到读不了它的来源上。
	need := requiredCapabilities(fields)
	if !modelSupports(model, need) {
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, capabilityDetail(need))
		return
	}
	session := routingSessionKey(userID, opts.SessionID, r.Header, fields["prompt_cache_key"], fields["input"])
	stripClientHints(fields)
	plan := attemptPlan{
		model:      model,
		session:    session,
		candidates: p.router.candidates(model, session, need),
		reserve:    reserve,
	}
	reply, err := p.dispatch(reqCtx, &plan, fields, stream, output, deadline)
	if err != nil {
		if r.Context().Err() != nil {
			return // client went away
		}
		if (guard != nil && guard.fromBudget && guard.expired.Load()) || errors.Is(err, context.DeadlineExceeded) {
			writeRoundExpired(w, r)
			return
		}
		if errors.Is(err, errInstanceBusy) {
			httpx.TooMany(w, r, 1)
			return
		}
		if errors.Is(err, ErrQuotaExceeded) {
			p.writeQuotaExceeded(w, r, userID, day, KindChat, quotaReasonOf(err))
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
		// 所有候选都在交付有效输出之前失败了：客户端据此进入降级或恢复提示，
		// 不需要自己从状态码推断。
		httpx.WriteProblemExtra(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, detail,
			map[string]any{"reason": "candidates_exhausted"})
		return
	}
	if reply.status < 200 || reply.status >= 300 {
		writeUpstreamStatus(w, r, reply.status, reply.retryAfter)
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
		body = &streamLimit{body: body, left: p.cfg.MaxResponseBytes}
	}
	result, end, streamErr, clientWriteFailed := p.copyStream(w, body)
	outcome := end.outcome()
	outcome.sourceReached = true
	switch {
	case r.Context().Err() != nil || clientWriteFailed:
		outcome = healthOutcome{reason: "客户端已取消请求"}
		result.clientCanceled = true
	case guard.fromBudget && guard.expired.Load():
		// 本轮预算在服务端这一侧用完：不是来源的故障，按取消计，不增加失败数。
		outcome = healthOutcome{reason: "本轮预算用完"}
		result.clientCanceled = true
	case errors.Is(streamErr, errResponseTooLarge):
		// 实例的响应字节上限到了：来源已经把这段回答生成并转出，是代理自己停下
		// 来的。按没有来源故障结束，不把代理的上限算成来源的毛病、让它进冷却。
		outcome = healthOutcome{reason: "流式响应超过上限", sourceReached: true}
		p.log.Warn("流式响应超过上限",
			slog.String("request_id", httpx.RequestIDFrom(r.Context())),
			slog.String("provider", reply.route.Provider.ID),
			slog.String("upstream_model", reply.route.UpstreamModel),
			slog.Int64("limit_bytes", p.cfg.MaxResponseBytes))
	}
	result.outputLimited = end == responseOutputLimit
	p.finishAttempt(&plan, reply.attempt, result, reply.status, outcome)
}

// writeRoundExpired 表示这一轮回答的预算已经用完，服务端没有交付任何有效输出。
// 客户端据此进入降级或恢复提示，不再等待这一轮。
func writeRoundExpired(w http.ResponseWriter, r *http.Request) {
	httpx.WriteProblem(w, r, http.StatusGatewayTimeout, httpx.CodeUpstreamFailed,
		"this round's time budget is used up before a model source answered")
}

// maxSessionIDBytes 是客户端讨论标识的长度上限。超长或为空的标识按没有处理，
// 不让它影响路由选择，也不写进日志。
const maxSessionIDBytes = 64

// 第三方会话标识可以带前缀，例如 OpenCode 的 ses_ 加 64 位十六进制字符。
const maxClientSessionIDBytes = 128

// sessionKey 按账号散列讨论标识，供知新调度与来源的缓存亲和使用。
func sessionKey(userID string, raw *string, maxBytes int) string {
	if raw == nil {
		return ""
	}
	id := strings.TrimSpace(*raw)
	if id == "" || len(id) > maxBytes {
		return ""
	}
	sum := sha256.Sum256([]byte(userID + "\x00" + id))
	return hex.EncodeToString(sum[:16])
}

// routingSessionKey 依次取知新标识、第三方会话头、缓存键和首条用户消息。
func routingSessionKey(userID string, explicit *string, headers http.Header, cacheKey, input json.RawMessage) string {
	if key := sessionKey(userID, explicit, maxSessionIDBytes); key != "" {
		return key
	}
	for _, name := range []string{
		"X-OpenCode-Session", "X-Session-Affinity", "X-Session-Id",
		"X-DeepSeek-Harness-Session-Id", "X-OpenCode-Session-Id",
	} {
		id := headers.Get(name)
		if key := sessionKey(userID, &id, maxClientSessionIDBytes); key != "" {
			return key
		}
	}
	var id string
	if len(cacheKey) > 0 && json.Unmarshal(cacheKey, &id) == nil {
		if key := sessionKey(userID, &id, maxClientSessionIDBytes); key != "" {
			return key
		}
	}
	// 缺少标识时，只要保留首条用户消息，追加消息和变动的 instructions 都不影响调度。
	decoder := json.NewDecoder(bytes.NewReader(input))
	if start, err := decoder.Token(); err != nil || start != json.Delim('[') {
		return ""
	}
	for decoder.More() {
		var item struct {
			Type    string          `json:"type"`
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		}
		if err := decoder.Decode(&item); err != nil {
			return ""
		}
		if item.Role != "user" || (item.Type != "" && item.Type != "message") {
			continue
		}
		content := item.Content
		if isJSONString(content) {
			var text string
			if json.Unmarshal(content, &text) != nil || strings.TrimSpace(text) == "" {
				return ""
			}
		} else if !isJSONArray(content) {
			return ""
		}
		var compact bytes.Buffer
		if json.Compact(&compact, content) != nil || compact.Len() <= 2 {
			return ""
		}
		// 独立的命名空间避免显式标识与消息派生的键重合。
		hash := sha256.New()
		hash.Write([]byte("first-user-message\x00" + userID + "\x00"))
		hash.Write(compact.Bytes())
		return "input:" + hex.EncodeToString(hash.Sum(nil)[:16])
	}
	return ""
}

// roundDeadline 把客户端带来的本轮剩余预算换成截止时间：客户端不给值时返回零
// 时间，只按本机时限执行；超过 RoundBudgetMax 的值按上限截断；值为 0 时截止
// 时间就是现在。传递的是一段时长而不是绝对时间，两端时钟不一致也不受影响。
func (p *Proxy) roundDeadline(raw *int64) time.Time {
	if raw == nil {
		return time.Time{}
	}
	left := time.Duration(*raw) * time.Millisecond
	if limit := p.cfg.RoundBudgetMax; limit > 0 && left > limit {
		left = limit
	}
	if left < 0 {
		left = 0
	}
	return p.now().Add(left)
}

// responseTimeout 是整段回答在服务端这一侧的时限：取 StreamTotalTimeout 与本轮
// 剩余预算中较小的一个，没有客户端预算时只按 StreamTotalTimeout。调用前已经核对
// 过预算没有用完，所以有截止时间时返回值总是正的；没有时限时返回 0。
func (p *Proxy) responseTimeout(deadline time.Time) time.Duration {
	limit := p.cfg.StreamTotalTimeout
	if deadline.IsZero() {
		return limit
	}
	if left := deadline.Sub(p.now()); limit <= 0 || left < limit {
		return left
	}
	return limit
}

// responsesOutputLimit 确定用于预留和转发的输出上限。访问令牌省略时使用 4096，
// 接入密钥省略或提供无效值时使用上限 32768，整数越界时取最近的边界。
func responsesOutputLimit(fields map[string]json.RawMessage, lenient bool) (int64, error) {
	raw, ok := fields["max_output_tokens"]
	var output int64
	switch {
	case lenient && (!ok || bytes.Equal(bytes.TrimSpace(raw), []byte("null"))):
		output = maxOutputTokens
	case !ok:
		output = defaultOutputTokens
	case json.Unmarshal(raw, &output) != nil:
		if !lenient {
			return 0, fmt.Errorf("max_output_tokens must be between %d and %d", minOutputTokens, maxOutputTokens)
		}
		output = maxOutputTokens
	}
	if output < minOutputTokens || output > maxOutputTokens {
		if !lenient {
			return 0, fmt.Errorf("max_output_tokens must be between %d and %d", minOutputTokens, maxOutputTokens)
		}
		if output < minOutputTokens {
			output = minOutputTokens
		} else {
			output = maxOutputTokens
		}
	}
	fields["max_output_tokens"] = json.RawMessage(strconv.FormatInt(output, 10))
	return output, nil
}

// 对话输出上限的三个数字，单位是 token。客户端按上下文上限的四分之一计算，
// 最高取到 maxOutputTokens，服务端对访问令牌按同一组数字校验（ADR-0055）。
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

// writeUpstreamStatus 把最后一次上游拒绝转给客户端。上游限流单独用
// `rate_limited` 与 `Retry-After` 表示：客户端据此提示稍后重试，与账号当天
// 额度用完（`quota_exceeded`）区分开。
func writeUpstreamStatus(w http.ResponseWriter, r *http.Request, status int, retryAfter string) {
	code, detail := httpx.CodeUpstreamFailed, "model source could not complete the request"
	switch {
	case keyRejected(status) || status < 400:
		status = http.StatusBadGateway
	case status == http.StatusTooManyRequests:
		code, detail = httpx.CodeRateLimited, "model source is temporarily rate limited"
		if retryAfter != "" {
			w.Header().Set("Retry-After", retryAfter)
		}
	}
	httpx.WriteProblem(w, r, status, code, detail)
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
// 上游会把用户内容保存在模型来源一侧。转发前一律改写成 false。
var chatFields = map[string]bool{
	"model": true, "instructions": true, "input": true,
	"max_output_tokens": true, "temperature": true, "top_p": true,
	"stream": true, "tools": true, "tool_choice": true, "parallel_tool_calls": true,
	"reasoning": true, "text": true, "store": true,
}

// clientHintFields 是第三方 Responses 客户端常见、接受但不原样转发的字段。
// prompt_cache_key 参与会话调度，其他提示字段由服务端与来源决定。
var clientHintFields = map[string]bool{
	"prompt_cache_key": true, "prompt_cache_retention": true, "prompt_cache_options": true,
	"service_tier": true, "include": true,
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

func allowFields(w http.ResponseWriter, r *http.Request, fields map[string]json.RawMessage, lenient bool, allowed ...map[string]bool) bool {
	for name := range fields {
		ok := false
		for _, set := range allowed {
			if set[name] {
				ok = true
				break
			}
		}
		if ok {
			continue
		}
		if lenient {
			// 第三方工具会带上服务端还没实现的字段；删掉再转发，比整次拒绝有用。
			delete(fields, name)
			continue
		}
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "unsupported model request field")
		return false
	}
	return true
}

// stripClientHints 删掉接受但不转发的字段，剩下的才是交给来源的请求体。
func stripClientHints(fields map[string]json.RawMessage) {
	for name := range clientHintFields {
		delete(fields, name)
	}
}

// upstreamErrorSnippet 取来源错误体的开头一小段，只用于日志。来源的拒绝原因
// 通常写在这里（参数名、类型、越界值），不读出来就只能看到一句 upstream_failed；
// 长度上限保证来源返回一页 HTML 时也不会把日志撑大。
func upstreamErrorSnippet(body io.Reader) string {
	b, _ := io.ReadAll(io.LimitReader(body, 300))
	return strings.TrimSpace(string(b))
}

// retryable 报告这个状态码是否换下一个来源再试：限流、服务端错误、key 被拒与
// 上游账户欠费都可能只是这个来源的问题；400、404、422 这类说明请求本身有问题，
// 换来源也一样，直接返回给客户端。402 的含义见 httpFailure 与 ADR-0075。
func retryable(status int) bool {
	return status == http.StatusUnauthorized || status == http.StatusForbidden ||
		status == http.StatusPaymentRequired ||
		status == http.StatusRequestTimeout || status == http.StatusTooManyRequests ||
		status >= 500
}

type chatReply struct {
	route      liveRoute
	status     int
	body       []byte
	stream     io.ReadCloser
	attempt    routeAttempt
	completion responseCompletion
	// retryAfter 是上游最后一次拒绝时给出的等待时长，原样转给客户端。
	retryAfter string
}

// dispatch tries the next candidate while a response can still be replaced.
// For a stream, ownership of its body and its settlement moves to Responses.
// deadline 是本轮截止时间，用于给每次流式尝试分到等待首个输出的时间。
func (p *Proxy) dispatch(ctx context.Context, plan *attemptPlan, fields map[string]json.RawMessage, stream bool, output int64, deadline time.Time) (chatReply, error) {
	var lastErr error = errors.New("no usable route")
	var reply chatReply
	// 预留按与客户端相同的口径估算：输入按请求里的文字与图片算，不按请求体
	// 字节数算；输出按常见长度占位。估算一律当作未命中缓存，结算时再按来源报告
	// 的 usage 多退少补。
	estimate := Usage{Input: estimateChatInput(fields), Output: reservedOutput(output)}
	for i, rt := range plan.candidates {
		if !p.attemptsRemain(plan) {
			break
		}
		if err := ctx.Err(); err != nil {
			return reply, err
		}
		if !deadline.IsZero() && !p.now().Before(deadline) {
			return reply, context.DeadlineExceeded
		}
		body, err := responsesUpstreamBody(fields, rt, plan.session)
		if err != nil {
			return reply, err
		}
		var firstOutput time.Duration
		var budgetOnly bool
		if stream {
			firstOutput, budgetOnly = p.firstOutputBudget(plan, i, deadline)
		}
		attempt, started, err := p.beginAttempt(ctx, plan, rt, estimate)
		if err != nil {
			return reply, err
		}
		if !started {
			continue
		}
		reply = chatReply{route: rt, attempt: attempt}
		attemptStarted := p.now()
		resp, err := p.attempt(ctx, rt.Provider, upstreamResponsesPath, body, stream, firstOutput, plan.session)
		if err != nil {
			if budgetOnly && errors.Is(err, errFirstOutputTimeout) {
				// 最后一次尝试的首字时限就是这一轮剩下的时间，它到点说明预算用完；
				// 本轮总时限的计时器与首字时限的计时器可能同时到点，谁先触发都按
				// 预算用完结束，不算来源故障，也不让客户端收到 candidates_exhausted。
				p.finishAttempt(plan, attempt, attemptResult{clientCanceled: true}, 0,
					healthOutcome{reason: "本轮预算用完", sourceReached: true})
				return reply, context.DeadlineExceeded
			}
			// 连接都没有建立时上游不可能计费，记 0；已经连上之后超时或被取消
			// 的尝试按输入估算结算，见 billedTokens。
			var connection sourceConnectionError
			p.finishAttempt(plan, attempt, attemptResult{unbilled: errors.As(err, &connection)}, 0, requestFailure(ctx, err))
			if ctx.Err() != nil {
				return reply, ctx.Err()
			}
			lastErr = err
			continue
		}
		reply.status = resp.StatusCode
		mediaType, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type"))
		// 来源回一份页面或 problem+json 错误时，换下一个来源：网关的故障页与
		// 来源自己的错误体都不是客户端的对话响应，照抄给客户端只会让调用方按
		// 格式错误结束。流式请求另有下面的流式类型检查，这里只管整段响应。
		if !stream && reply.status != http.StatusUnauthorized && (mediaType == "text/html" || mediaType == "application/problem+json") {
			resp.Body.Close()
			outcome := httpFailure(reply.status, resp.Header.Get("Retry-After"))
			outcome.reason, outcome.scope = "响应类型不可用", routeFailure
			// 页面与 problem 里没有可核对的上游用量，来源多半没有计费，按没有产生
			// 上游费用记 0；非 2xx 是明确拒绝，同样记 0（ADR-0070）。
			p.finishAttempt(plan, attempt, attemptResult{unbilled: true}, reply.status, outcome)
			lastErr = errors.New("provider did not return a usable response")
			continue
		}
		if reply.status < 200 || reply.status >= 300 {
			// 来源的拒绝原因只有来源自己的错误体里才有；不读出来，客户端只能看到
			// 一句 upstream_failed，排查时无从下手。只取开头一小段，请求内容不进
			// 日志（ADR-0052 的“请求体与响应体不记录”不因此改变）。
			snippet := upstreamErrorSnippet(resp.Body)
			resp.Body.Close()
			reply.retryAfter = resp.Header.Get("Retry-After")
			p.log.Warn("模型来源拒绝了请求",
				slog.String("request_id", httpx.RequestIDFrom(ctx)),
				slog.String("provider", rt.Provider.ID),
				slog.String("upstream_model", rt.UpstreamModel),
				slog.Int("status", reply.status),
				slog.String("error", snippet),
			)
			p.finishAttempt(plan, attempt, attemptResult{unbilled: true}, reply.status,
				httpFailure(reply.status, reply.retryAfter))
			if retryable(reply.status) {
				lastErr = nil
				continue
			}
			return reply, nil
		}
		if stream {
			if mediaType == "application/json" || mediaType == "text/html" || mediaType == "application/problem+json" {
				// 来源用 2xx 回了一份整段响应（来源忽略了 stream，或者回的是错误
				// 体）。请求可能已经被处理并计费：响应里带 usage 就按 usage 结算，
				// 能解析成 Responses 响应对象就按正文估算输出，两者都拿不到时才按
				// 没有产生上游费用记 0（ADR-0070）。正文不转给客户端，换下一个来源。
				amount, output := p.discardedUsage(resp.Body, mediaType)
				result := attemptResult{usage: amount, outputEstimate: output}
				result.unbilled = amount.Total() <= 0 && output <= 0
				p.finishAttempt(plan, attempt, result, reply.status,
					healthOutcome{reason: "流式响应类型不可用", scope: routeFailure, sourceReached: true})
				lastErr = errors.New("provider did not return a chat stream")
				continue
			}
			// 首个有效输出之前先暂存，收到响应头、心跳与开场事件后仍能换路。
			if firstOutput <= 0 {
				reply.stream = resp.Body
				return reply, nil
			}
			wait := firstOutput - p.now().Sub(attemptStarted)
			if !deadline.IsZero() {
				if left := deadline.Sub(p.now()); left < wait {
					wait = left
				}
			}
			gate := p.gateFirstOutput(resp.Body, wait)
			if gate.timeout {
				resp.Body.Close()
				// 首字时限来自本轮预算时，是这一轮没有时间了，不算来源故障。
				if !deadline.IsZero() && !p.now().Before(deadline) {
					p.finishAttempt(plan, attempt, attemptResult{clientCanceled: true}, reply.status,
						healthOutcome{reason: "本轮预算用完", sourceReached: true})
					return reply, context.DeadlineExceeded
				}
				p.finishAttempt(plan, attempt, attemptResult{}, reply.status,
					healthOutcome{reason: "首个有效输出超时", scope: routeFailure, sourceReached: true})
				lastErr = errors.New("model source did not deliver output in time")
				continue
			}
			if gate.err != nil {
				resp.Body.Close()
				if ctx.Err() != nil {
					p.finishAttempt(plan, attempt, attemptResult{}, reply.status,
						healthOutcome{reason: "请求已取消或超时"})
					return reply, ctx.Err()
				}
				reason := "首个有效输出之前中断"
				if errors.Is(gate.err, errPreludeTooLarge) {
					reason = errPreludeTooLarge.Error()
				}
				p.finishAttempt(plan, attempt, attemptResult{}, reply.status,
					healthOutcome{reason: reason, scope: routeFailure, sourceReached: true})
				lastErr = gate.err
				continue
			}
			if gate.failure != nil {
				resp.Body.Close()
				result, status, outcome := preludeFailure(gate.failure, resp.Header.Get("Retry-After"))
				// 首个有效输出之前收到终止事件：事件里没有用量时来源明确报告这次
				// 失败，按没有产生计费结算；带用量时按用量结算。
				result.unbilled = result.usage.Total() <= 0
				p.finishAttempt(plan, attempt, result, reply.status, outcome)
				lastErr = errors.New(outcome.reason)
				if status != 0 {
					reply.status, reply.retryAfter = status, outcome.retryAfter
					lastErr = nil
				}
				continue
			}
			reply.stream = &prefixed{head: bytes.NewReader(gate.buf), body: resp.Body}
			return reply, nil
		}
		// 非流式响应要整段读进内存再写回客户端：先按上限从实例预算里预留，
		// 占不到时没有写出任何内容，整次请求按实例繁忙结束，不换来源重试。
		release, reserved := p.mem.reserve(p.cfg.MaxResponseBytes)
		if !reserved {
			// 来源已经用 2xx 回了响应，可能已经计费，但正文被直接关掉、拿不到
			// 任何用量；客户端收到 429 会重试，这次不向账号结算，成本由实例承担。
			resp.Body.Close()
			p.finishAttempt(plan, attempt, attemptResult{unbilled: true}, reply.status,
				healthOutcome{reason: "服务端响应预算不足", sourceReached: true})
			return reply, errInstanceBusy
		}
		b, err := readResponse(resp.Body, p.cfg.MaxResponseBytes)
		resp.Body.Close()
		release()
		var response responseObject
		if err == nil {
			response, err = parseResponseObject(b)
		}
		amount := parseUsage(b, KindChat)
		if err != nil {
			outcome := healthOutcome{reason: "聊天响应不可用", scope: routeFailure, sourceReached: true}
			if ctx.Err() != nil {
				p.finishAttempt(plan, attempt, attemptResult{usage: amount}, reply.status,
					healthOutcome{reason: "请求已取消或超时"})
				return reply, ctx.Err()
			}
			p.finishAttempt(plan, attempt, attemptResult{usage: amount}, reply.status, outcome)
			lastErr = err
			continue
		}
		end := responseEnd(response.Status, response.IncompleteDetails)
		outcome := end.outcome()
		outcome.sourceReached = true
		p.finishAttempt(plan, attempt, attemptResult{
			usage:          amount,
			outputEstimate: estimateResponseOutput(response.Output),
			success:        end == responseCompleted, outputLimited: end == responseOutputLimit,
		}, reply.status, outcome)
		if outcome.scope == routeFailure {
			lastErr = errors.New(outcome.reason)
			continue
		}
		reply.body, reply.completion = b, end
		return reply, nil
	}
	return reply, lastErr
}

// firstOutputBudget 给这一次流式尝试分到等待首个有效输出的时间：不超过
// FirstOutputTimeout（没有配置时退回 HeaderTimeout），也不超过本轮剩余预算按
// 还能尝试的候选数平分的份额，首发与备用因此都落在同一轮预算内。返回的第二个值
// 表示这个时限取自本轮剩余预算、而且这是最后一次允许的尝试，它到点就等于预算
// 用完，调用方据此回 504 而不是把来源的首字超时当成来源故障。没有配置任何时限、
// 也没有客户端预算时返回 0，表示不设这个期限；本轮预算是否已经用完由 dispatch
// 在发起尝试之前核对。
func (p *Proxy) firstOutputBudget(plan *attemptPlan, index int, deadline time.Time) (time.Duration, bool) {
	limit := p.cfg.FirstOutputTimeout
	if limit <= 0 {
		limit = p.cfg.HeaderTimeout
	}
	if deadline.IsZero() {
		return limit, false
	}
	left := deadline.Sub(p.now())
	if left <= 0 {
		return 0, false
	}
	remaining := len(plan.candidates) - index
	if p.cfg.MaxAttempts > 0 {
		if room := p.cfg.MaxAttempts - plan.started; room < remaining {
			remaining = room
		}
	}
	if remaining < 1 {
		remaining = 1
	}
	share := left / time.Duration(remaining)
	if limit <= 0 || share < limit {
		return share, remaining <= 1
	}
	return limit, false
}

// upstreamResponsesPath 是来源侧接收对话请求的路径。来源都是 OpenAI 兼容地址，
// 以 /v1 结尾；管理员在后台配置来源时写的就是这个结尾。
const upstreamResponsesPath = "/responses"

// attempt 向一个来源发一次请求。eventStream 表示这是等待流式事件的聊天请求，
// 请求带上 Accept: text/event-stream；headerTimeout 大于 0 时，响应头必须在这段
// 时间内到达，否则尝试下一条路由。非流式聊天要等整段回答生成完才有响应头，传 0。
//
// session 是这条讨论的调度键，同时作为 OpenCode Go 通道要求的 `x-opencode-session`
// 头发出去：它的网关按这个头把同一会话的请求排到同一个上游，缺这个头直接回 400
// `MissingSessionID`。其余来源忽略这个头，只在地址指向 OpenCode 时才带。
func (p *Proxy) attempt(ctx context.Context, prov *liveProvider, path string, body []byte, eventStream bool, headerTimeout time.Duration, session string) (*http.Response, error) {
	actx, cancel := context.WithCancel(ctx)
	var gotConnection atomic.Bool
	actx = httptrace.WithClientTrace(actx, &httptrace.ClientTrace{
		GotConn: func(httptrace.GotConnInfo) { gotConnection.Store(true) },
	})
	req, err := http.NewRequestWithContext(actx, http.MethodPost, prov.BaseURL+path, bytes.NewReader(body))
	if err != nil {
		cancel()
		return nil, sourceConnectionError{err}
	}
	req.Header.Set("Content-Type", "application/json")
	if prov.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+prov.APIKey)
	}
	if eventStream {
		req.Header.Set("Accept", "text/event-stream")
	}
	host := strings.ToLower(req.URL.Hostname())
	if path == upstreamResponsesPath && (host == "opencode.ai" || strings.HasSuffix(host, ".opencode.ai")) {
		if session == "" {
			// 后台自测与探活没有讨论标识，用固定值即可：这个头只要求同一个会话内
			// 稳定，否则网关按缺少会话标识拒绝整次请求。
			session = "zhixin-probe"
		}
		req.Header.Set("x-opencode-session", session)
	}
	var timer *time.Timer
	if headerTimeout > 0 {
		timer = time.AfterFunc(headerTimeout, cancel)
	}
	resp, err := p.sendToProvider(req, prov)
	if timer != nil && !timer.Stop() {
		// 期限在 Do 返回前后到点：响应体已经被取消，当作超时。
		if err == nil {
			resp.Body.Close()
		}
		cancel()
		resp, err = nil, fmt.Errorf("%w (no response within %s)", errFirstOutputTimeout, headerTimeout)
	}
	if err != nil {
		cancel()
		if !gotConnection.Load() {
			err = sourceConnectionError{err}
		}
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

// writeQuotaExceeded 回 429 quota_exceeded，并带上当天的账号用量、账号额度、实例
// 预算与用完的是哪一种额度：客户端按 reason 决定是引导购买积分还是只说稍后再试。
func (p *Proxy) writeQuotaExceeded(w http.ResponseWriter, r *http.Request, userID, day string, kind Kind, reason QuotaReason) {
	used, err := p.quota.Used(r.Context(), userID, day, "")
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	limit, err := p.dailyLimit(r.Context(), userID)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	instanceUsed, err := p.quota.InstanceUsed(r.Context(), day)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	detail := "daily free allowance used up"
	switch reason {
	case QuotaReasonPoints:
		detail = "available points are not enough for this request"
	case QuotaReasonInstance:
		detail = "instance daily budget used up"
	case QuotaReasonSyncing:
		detail = "the points balance is being synced; retry later"
	}
	httpx.WriteProblemExtra(w, r, http.StatusTooManyRequests, httpx.CodeQuotaExceeded, detail,
		map[string]any{
			"reason":                string(reason),
			"day":                   day,
			"kind":                  string(kind),
			"used_tokens":           used,
			"daily_tokens":          limit,
			"instance_used_tokens":  instanceUsed,
			"instance_daily_tokens": p.cfg.InstanceDailyTokens,
		})
}

// quotaReasonOf 读出预留被拒的原因；不是带原因的额度错误时按账号额度用完处理。
func quotaReasonOf(err error) QuotaReason {
	var quota *QuotaExceededError
	if errors.As(err, &quota) {
		return quota.Reason
	}
	return QuotaReasonAccount
}

// usageEnvelope 读 Responses 与 Embeddings 两种响应里的用量：对话是
// input_tokens、output_tokens 与 total_tokens，嵌入是 prompt_tokens 与
// total_tokens，两种都认，取值以实际出现的字段为准。
type usageEnvelope struct {
	Usage *struct {
		InputTokens  int64 `json:"input_tokens"`
		OutputTokens int64 `json:"output_tokens"`
		PromptTokens int64 `json:"prompt_tokens"`
		TotalTokens  int64 `json:"total_tokens"`
		// InputTokensDetails 是 Responses 在命中上下文缓存时给出的明细，命中量
		// 读 cached_tokens；没有这个对象表示来源不支持或这次没有命中数据。
		// 命中量用指针，用来区分“来源报了 0”（这次确实没有命中）与“来源没有
		// 这个字段”（这次拿不到命中数据）。
		InputTokensDetails *struct {
			CachedTokens *int64 `json:"cached_tokens"`
		} `json:"input_tokens_details"`
	} `json:"usage"`
}

// input 返回来源报告的输入量、其中命中缓存的部分，以及来源有没有给出缓存字段。
// 没有输入量时缓存命中量也不单列，因为没有可用的分母，也就不算一条缓存上报；
// 命中量超过输入量时按输入量截断。
func (u usageEnvelope) input() (input, cached int64, reported bool) {
	if u.Usage == nil {
		return 0, 0, false
	}
	input = u.Usage.InputTokens
	if u.Usage.InputTokensDetails != nil && u.Usage.InputTokensDetails.CachedTokens != nil {
		cached, reported = *u.Usage.InputTokensDetails.CachedTokens, true
	}
	if input <= 0 {
		return 0, 0, false
	}
	if cached > input {
		cached = input
	}
	if cached < 0 {
		cached = 0
	}
	return input, cached, reported
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

// usage 把 envelope 里的字段整理成一次调用的用量。聊天在来源只报总量时不填
// Input 与 Cached，让 Billed 退回按原始 token 记账，避免把未知的输入当成输出。
func (u usageEnvelope) usage(kind Kind) Usage {
	if u.Usage == nil {
		return Usage{}
	}
	if kind == KindEmbedding {
		return Usage{Input: u.tokens(kind)}
	}
	input, cached, reported := u.input()
	out := Usage{Input: input, Cached: cached, CachedReported: reported}
	if total := u.tokens(kind); total > 0 {
		out.Output = max(total-input, 0)
	} else {
		out.Output = max(u.Usage.OutputTokens, 0)
	}
	return out
}

type incompleteDetails struct {
	Reason string `json:"reason"`
}

type responseObject struct {
	ID                string                       `json:"id"`
	Object            string                       `json:"object"`
	Output            []map[string]json.RawMessage `json:"output"`
	Status            string                       `json:"status"`
	IncompleteDetails incompleteDetails            `json:"incomplete_details"`
}

func parseResponseObject(b []byte) (responseObject, error) {
	var env responseObject
	if err := json.Unmarshal(b, &env); err != nil {
		return env, err
	}
	if env.Output == nil && env.Object != "response" && env.ID == "" {
		return env, errors.New("invalid response object")
	}
	return env, nil
}

type responseCompletion uint8

const (
	responseInterrupted responseCompletion = iota
	responseCompleted
	responseOutputLimit
	responseIncomplete
	responseFailed
)

func responseEnd(status string, details incompleteDetails) responseCompletion {
	switch status {
	case "", "completed":
		return responseCompleted
	case "failed":
		return responseFailed
	case "incomplete":
		if details.Reason == "max_output_tokens" {
			return responseOutputLimit
		}
		return responseIncomplete
	default:
		return responseIncomplete
	}
}

func (end responseCompletion) outcome() healthOutcome {
	switch end {
	case responseCompleted:
		return healthOutcome{}
	case responseOutputLimit:
		return healthOutcome{reason: "回答达到输出上限"}
	case responseIncomplete:
		return healthOutcome{reason: "上游未完成回答", scope: routeFailure}
	case responseFailed:
		return healthOutcome{reason: "上游报告回答失败", scope: routeFailure}
	default:
		return healthOutcome{reason: "流式响应提前结束", scope: routeFailure}
	}
}

// errFirstOutputTimeout 表示等待来源首个有效输出（响应头）的时限到了。这个时限
// 可能取自本轮剩余预算，调用方据此区分来源慢与这一轮没有时间了。
var errFirstOutputTimeout = errors.New("llmproxy: 首个有效输出超时")

// errResponseTooLarge 表示上游响应超过配置的字节上限。非流式响应在写响应头之前
// 发现，调用方按 upstream_failed 回 problem，而不是把半截响应交给客户端；流式
// 响应在转发途中发现，调用方结束这次转发，已转出的内容照常交付，但不把到达上限
// 当成来源故障。
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

// discardedUsage 读一份不会转给客户端的 2xx 响应体，取出 usage 与整段响应的输出
// 估算：有 usage 时以 usage 为准，没有时只要能解析成 Responses 响应对象就按正文
// 估算输出。实例响应预算不够或正文不是 JSON 时返回零值，调用方据此把这次尝试记为
// 没有产生上游费用。
func (p *Proxy) discardedUsage(body io.ReadCloser, mediaType string) (Usage, int64) {
	release, reserved := p.mem.reserve(p.cfg.MaxResponseBytes)
	if !reserved {
		body.Close()
		return Usage{}, 0
	}
	b, _ := readResponse(body, p.cfg.MaxResponseBytes)
	body.Close()
	release()
	if mediaType != "application/json" {
		return Usage{}, 0
	}
	if amount := parseUsage(b, KindChat); amount.Total() > 0 {
		return amount, 0
	}
	response, err := parseResponseObject(b)
	if err != nil {
		return Usage{}, 0
	}
	return Usage{}, estimateResponseOutput(response.Output)
}

// parseUsage 从一段响应体里读用量，聊天与嵌入共用。额度结算、账号统计与路由
// 统计都靠它取数，同一条响应只解析一次，不再各解析一遍而口径不一。
func parseUsage(b []byte, kind Kind) Usage {
	var env usageEnvelope
	if json.Unmarshal(b, &env) != nil {
		return Usage{}
	}
	return env.usage(kind)
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
	// fromBudget 表示总时限取自本轮预算而不是 StreamTotalTimeout；到点后调用方
	// 把这次结束记成预算用完，不算来源故障。
	fromBudget bool
	expired    atomic.Bool
}

// newStreamGuard 创建可取消的上游 context 与守卫；总时限是 StreamTotalTimeout
// 与本轮剩余预算中较小的一个，创建时立即开始计时。
func (p *Proxy) newStreamGuard(ctx context.Context, deadline time.Time) (context.Context, *streamGuard) {
	ctx, cancel := context.WithCancel(ctx)
	guard := &streamGuard{cancel: cancel}
	total := p.cfg.StreamTotalTimeout
	if !deadline.IsZero() {
		if left := deadline.Sub(p.now()); total <= 0 || left < total {
			total, guard.fromBudget = left, true
		}
	}
	if total > 0 {
		guard.total = time.AfterFunc(total, guard.expire)
	}
	return ctx, guard
}

// expire 取消上游请求并记下时限到点，调用方据此区分来源故障与预算用完。
func (g *streamGuard) expire() {
	g.expired.Store(true)
	g.cancel()
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

// streamLimit 把一次流式转发限制在 left 字节以内。读满之后它只再从来源读一个
// 字节：读到了说明来源还有内容，以 errResponseTooLarge 结束，调用方据此分清代理
// 自己的上限与来源提前结束；要不到时按正常的 EOF 结束。io.LimitReader 截断之后
// 只回一个普通 EOF，转发代码看不出区别，来源因此会被误记成提前结束、进冷却。
type streamLimit struct {
	body io.Reader
	left int64
}

func (l *streamLimit) Read(p []byte) (int, error) {
	if l.left <= 0 {
		var probe [1]byte
		n, err := l.body.Read(probe[:])
		if n > 0 {
			return 0, errResponseTooLarge
		}
		return 0, err
	}
	if int64(len(p)) > l.left {
		p = p[:l.left]
	}
	n, err := l.body.Read(p)
	l.left -= int64(n)
	return n, err
}

// copyStream forwards SSE line by line, flushing at each blank line (event
// boundary), and picks the last usage object it sees. Failed or incomplete
// terminal events take precedence over a trailing [DONE] marker. The returned
// error is the one that ended the read, so the caller can tell a source that
// stopped early from the proxy's own byte limit; a client write failure is
// reported separately and comes with a nil error.
func (p *Proxy) copyStream(w http.ResponseWriter, body io.Reader) (result attemptResult, end responseCompletion, streamErr error, clientWriteFailed bool) {
	flusher, _ := w.(http.Flusher)
	rd := bufio.NewReaderSize(body, 64*1024)
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			trimmed := bytes.TrimRight(line, "\r\n")
			if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
				data = bytes.TrimSpace(data)
				completion, used := streamData(data)
				end = max(end, completion)
				// 没有 usage 时按已经转出的输出估算结算，所以逐条累计增量。
				result.outputEstimate += streamOutputTokens(data)
				if used.Total() > 0 {
					result.usage = used
				}
			}
			if _, werr := w.Write(line); werr != nil {
				return result, end, nil, true
			}
			if len(trimmed) == 0 && flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			if flusher != nil {
				flusher.Flush()
			}
			if end == responseCompleted && !errors.Is(err, io.EOF) {
				end = responseInterrupted
			}
			result.success = end == responseCompleted
			return result, end, err, false
		}
	}
}

// streamData 解析一条流事件的完成状态与用量：用量先取 response 包装里的一份，
// 没有再取事件自身的一份；[DONE] 只表示结束，不带用量。
func streamData(data []byte) (responseCompletion, Usage) {
	if bytes.Equal(data, []byte("[DONE]")) {
		return responseCompleted, Usage{}
	}
	var event struct {
		usageEnvelope
		Type     string `json:"type"`
		Response struct {
			usageEnvelope
			IncompleteDetails incompleteDetails `json:"incomplete_details"`
		} `json:"response"`
	}
	if json.Unmarshal(data, &event) != nil {
		return responseInterrupted, Usage{}
	}
	amount := event.Response.usage(KindChat)
	if amount.Total() <= 0 {
		amount = event.usage(KindChat)
	}
	switch event.Type {
	case "response.completed":
		return responseCompleted, amount
	case "response.incomplete":
		return responseEnd("incomplete", event.Response.IncompleteDetails), amount
	case "response.failed":
		return responseFailed, amount
	}
	return responseInterrupted, amount
}
