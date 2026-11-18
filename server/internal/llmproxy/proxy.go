// Package llmproxy forwards OpenAI Chat Completions requests to the provider
// with the server-held key (ADR-0008, ADR-0009).
//
// The client keeps its existing Chat Completions request builder and SSE
// parser: it points the base URL at <server>/v1/llm and sends its access
// token as the key. The proxy checks the model allow-list and the daily
// budget, swaps the credential, and copies the response through, flushing
// every chunk. Request and response bodies are never logged or stored; only
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
	"net/http"
	"slices"
	"sync"
	"time"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

type Proxy struct {
	cfg    config.LLMConfig
	quota  Quota
	client *http.Client
	loc    *time.Location
	now    func() time.Time
	log    *slog.Logger

	// verifyEmail 判断账号是否已经确认邮箱；由 server.New 注入账号库的 UserByID。
	// 没有注入时按已认证处理，现有内存装配与测试因此不需要真实账号也能走通。
	verifyEmail func(ctx context.Context, userID string) (bool, error)

	// maxPerUser 是同一账号同时进行的托管请求上限，由 SetConcurrencyLimit 设置，
	// 小于等于 0 表示不限制。inflight 记在途请求数，由 mu 保护；计数归零时删键，
	// map 不随注册过的账号数增长。
	mu         sync.Mutex
	maxPerUser int
	inflight   map[string]int
}

// NewHandler 组装模型代理；构造函数与另外四个业务包同名。
func NewHandler(cfg config.LLMConfig, quota Quota, loc *time.Location, log *slog.Logger) *Proxy {
	// 额度上限只有配置一处来源：装配时交给配额实现，Reserve 用它做原子比较。
	// 接口之外的注入用可选方法，内存与 PostgreSQL 实现都支持。
	if setter, ok := quota.(quotaLimits); ok {
		setter.SetQuotaLimits(cfg.DailyTokens, cfg.InstanceDailyTokens)
	}
	// No overall client timeout: streams legitimately last minutes. The
	// client's own per-event deadlines (docs/00 §9) cancel the request,
	// which cancels r.Context() and with it the upstream call.
	return &Proxy{cfg: cfg, quota: quota, client: &http.Client{}, loc: loc, now: time.Now, log: log, inflight: map[string]int{}}
}

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

// models answers in the OpenAI list shape so the client's connection test works unchanged.
func (p *Proxy) Models(w http.ResponseWriter, r *http.Request) {
	data := make([]api.Model, 0, len(p.cfg.Models))
	for _, m := range p.cfg.Models {
		data = append(data, api.Model{Id: m, Object: "model", OwnedBy: "zhixin"})
	}
	httpx.WriteJSON(w, http.StatusOK, api.ModelList{Object: "list", Data: data})
}

func (p *Proxy) QuotaStatus(w http.ResponseWriter, r *http.Request) {
	pr := auth.MustPrincipal(r.Context())
	day := p.day()
	used, err := p.quota.Used(r.Context(), pr.UserID, day)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	limit, err := p.dailyLimit(r.Context(), pr.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.LLMQuota{
		Day:         openapi_types.Date{Time: p.dayTime()},
		UsedTokens:  used,
		DailyTokens: limit,
	})
}

// dailyLimit 返回账号当天可用的 token 上限：先看有没有按账号调整过的额度，
// 没有时用配置的默认值。调整写 llm_quota 表，不重启服务，下一次请求生效。
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

func (p *Proxy) Chat(w http.ResponseWriter, r *http.Request) {
	pr := auth.MustPrincipal(r.Context())
	if p.cfg.APIKey == "" {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "model proxy is not configured on this server")
		return
	}
	// 邮箱确认在读取请求体之前检查：未确认的账号拿 403，不消耗请求体读取、额度
	// 预留与上游调用。检查失败按服务端错误处理，不能当成“未确认”放过去。
	if p.cfg.RequireVerifiedEmail && p.verifyEmail != nil {
		verified, err := p.verifyEmail(r.Context(), pr.UserID)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return
		}
		if !verified {
			httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeEmailUnverified,
				"verify your email address on the account page to use the hosted model quota")
			return
		}
	}
	// 并发上限同样在读取请求体之前检查：超出时回 429 与 Retry-After，不占请求体
	// 读取、额度预留与上游连接。名额在请求结束（含流式转发）时由 defer 归还。
	if !p.acquireConcurrency(pr.UserID) {
		httpx.TooMany(w, r, 1)
		return
	}
	defer p.releaseConcurrency(pr.UserID)
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, p.cfg.MaxRequestBytes))
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, fmt.Sprintf("request exceeds %d bytes", p.cfg.MaxRequestBytes))
			return
		}
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "could not read body")
		return
	}
	// 只解释契约里声明的 model 与 stream，其余字段按原始字节转发给提供方：请求体
	// 是提供方的格式，服务端不重新编码。
	var head api.PostV1LlmChatCompletionsJSONBody
	if err := json.Unmarshal(body, &head); err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "body is not a JSON object")
		return
	}
	if !slices.Contains(p.cfg.Models, head.Model) {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeModelNotAllowed, "", map[string]any{"models": p.cfg.Models})
		return
	}
	stream := head.Stream != nil && *head.Stream
	day := p.day()
	// 转发前按请求体大小估算消耗并预留：估算不追求精确，结算时按提供方返回的
	// usage 多退少补；至少 1 个 token，避免空请求完全不占额度。账号额度与实例
	// 预算由配额实现在同一个临界区里比较，并发请求不会各自按旧用量通过。
	estimate := int64(len(body) / 4)
	if estimate < 1 {
		estimate = 1
	}
	reserved, err := p.quota.Reserve(r.Context(), pr.UserID, day, estimate)
	if errors.Is(err, ErrQuotaExceeded) {
		p.writeQuotaExceeded(w, r, pr.UserID, day)
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, p.log, err)
		return
	}

	// 预留之后的所有出口都结算一次：请求构造失败、上游不可达、响应读不完、超时
	// 都会走到这里，预留不会永远挂在账上。默认按预留保守记账，确实没有产生用量
	// 的路径在返回前改成 0。
	actual := reserved
	defer func() {
		// 用独立 context 结算：客户端可能在最后一个数据块之后已经断开，但用量已经
		// 发生。结算失败只记日志，响应已经写出，不能让客户端以为请求失败。
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		defer cancel()
		if err := p.quota.Settle(ctx, pr.UserID, day, reserved, actual); err != nil {
			p.log.Error("settle llm usage", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
		}
	}()

	// 流式响应套一层守卫：总时限从发起上游请求时开始，空闲时限从收到响应体之后
	// 开始；超时取消上游请求，阻塞中的读取随即返回。非流式沿用请求自身的 context。
	reqCtx := r.Context()
	var guard *streamGuard
	if stream {
		reqCtx, guard = p.newStreamGuard(reqCtx)
		defer guard.stop()
	}
	up, err := http.NewRequestWithContext(reqCtx, http.MethodPost, p.cfg.BaseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		actual = 0
		httpx.WriteInternal(w, r, p.log, err)
		return
	}
	up.Header.Set("Content-Type", "application/json")
	up.Header.Set("Authorization", "Bearer "+p.cfg.APIKey)
	if stream {
		up.Header.Set("Accept", "text/event-stream")
	}
	resp, err := p.client.Do(up)
	if err != nil {
		actual = 0 // 没有拿到响应，按没有产生用量退回预留。
		if r.Context().Err() != nil {
			return // client went away
		}
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, "could not reach the model provider")
		return
	}
	defer resp.Body.Close()

	// Pass the provider's status and body through, including errors: the
	// client already reads provider error bodies to explain key, quota and
	// model-name problems (app/README §模型).
	//
	// 非流式先把整个响应读进内存再写响应头：超过上限时还没有写出任何字节，可以
	// 换成代理自己的 502，客户端不会收到半截响应。
	var tokens int64
	if stream {
		guard.watch(resp.Body, p.cfg.StreamIdleTimeout)
		copyResponseHeaders(w, resp)
		w.WriteHeader(resp.StatusCode)
		tokens = p.copyStream(w, guard)
	} else {
		b, err := readResponse(resp.Body, p.cfg.MaxResponseBytes)
		if errors.Is(err, errResponseTooLarge) {
			httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed,
				fmt.Sprintf("provider response exceeds %d bytes", p.cfg.MaxResponseBytes))
			return
		}
		if err != nil {
			httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, "could not read the provider response")
			return
		}
		copyResponseHeaders(w, resp)
		w.WriteHeader(resp.StatusCode)
		_, _ = w.Write(b)
		tokens = usageTokens(b)
	}

	actual = tokens
	switch {
	case resp.StatusCode >= http.StatusBadRequest:
		// 上游错误没有产生回答，预留全部退回。
		actual = 0
	case actual <= 0:
		// 提供方没有给出 usage（例如流式请求没带 include_usage）时保留预留，
		// 不能按 0 全部退掉，否则调用方只受估算值的约束。
		actual = reserved
	}
}

// writeQuotaExceeded 回 429 quota_exceeded，并带上当天的账号用量、账号额度与
// 实例预算：客户端据此提示额度用完，响应里也能看出是哪一种额度用尽。
func (p *Proxy) writeQuotaExceeded(w http.ResponseWriter, r *http.Request, userID, day string) {
	used, err := p.quota.Used(r.Context(), userID, day)
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
	httpx.WriteProblemExtra(w, r, http.StatusTooManyRequests, httpx.CodeQuotaExceeded,
		"daily budget used up; use your own key or try again tomorrow",
		map[string]any{
			"day":                   day,
			"used_tokens":           used,
			"daily_tokens":          limit,
			"instance_used_tokens":  instanceUsed,
			"instance_daily_tokens": p.cfg.InstanceDailyTokens,
		})
}

type usageEnvelope struct {
	Usage *struct {
		TotalTokens int64 `json:"total_tokens"`
	} `json:"usage"`
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
func copyResponseHeaders(w http.ResponseWriter, resp *http.Response) {
	for _, h := range []string{"Content-Type", "Cache-Control"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
}

// usageTokens 从非流式响应体里取 usage.total_tokens；没有 usage 时返回 0。
func usageTokens(b []byte) int64 {
	var env usageEnvelope
	if json.Unmarshal(b, &env) == nil && env.Usage != nil {
		return env.Usage.TotalTokens
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
// boundary), and picks the last usage object it sees.
func (p *Proxy) copyStream(w http.ResponseWriter, body io.Reader) int64 {
	flusher, _ := w.(http.Flusher)
	rd := bufio.NewReaderSize(body, 64*1024)
	var tokens int64
	for {
		line, err := rd.ReadBytes('\n')
		if len(line) > 0 {
			if _, werr := w.Write(line); werr != nil {
				return tokens
			}
			trimmed := bytes.TrimRight(line, "\r\n")
			if data, ok := bytes.CutPrefix(trimmed, []byte("data:")); ok {
				data = bytes.TrimSpace(data)
				var env usageEnvelope
				if bytes.Contains(data, []byte(`"usage"`)) && json.Unmarshal(data, &env) == nil && env.Usage != nil {
					tokens = env.Usage.TotalTokens
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
			return tokens
		}
	}
}
