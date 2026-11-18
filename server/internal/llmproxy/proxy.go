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
	if used >= limit {
		httpx.WriteProblemExtra(w, r, http.StatusTooManyRequests, httpx.CodeQuotaExceeded,
			"daily budget used up; use your own key or try again tomorrow",
			map[string]any{"day": day, "used_tokens": used, "daily_tokens": limit})
		return
	}

	up, err := http.NewRequestWithContext(r.Context(), http.MethodPost, p.cfg.BaseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
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
	for _, h := range []string{"Content-Type", "Cache-Control"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.WriteHeader(resp.StatusCode)

	var tokens int64
	if stream {
		tokens = p.copyStream(w, resp.Body)
	} else {
		tokens = p.copyWhole(w, resp.Body)
	}
	if tokens > 0 {
		// Record with a fresh context: the client may already have hung up
		// after the final chunk, but the tokens were spent.
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		defer cancel()
		if err := p.quota.Add(ctx, pr.UserID, day, tokens); err != nil {
			p.log.Error("record llm usage", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
		}
	}
}

type usageEnvelope struct {
	Usage *struct {
		TotalTokens int64 `json:"total_tokens"`
	} `json:"usage"`
}

func (p *Proxy) copyWhole(w http.ResponseWriter, body io.Reader) int64 {
	b, err := io.ReadAll(body)
	_, _ = w.Write(b)
	if err != nil {
		return 0
	}
	var env usageEnvelope
	if json.Unmarshal(b, &env) == nil && env.Usage != nil {
		return env.Usage.TotalTokens
	}
	return 0
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
