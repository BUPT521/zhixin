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
	"time"

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
}

func New(cfg config.LLMConfig, quota Quota, loc *time.Location, log *slog.Logger) *Proxy {
	// No overall client timeout: streams legitimately last minutes. The
	// client's own per-event deadlines (docs/00 §9) cancel the request,
	// which cancels r.Context() and with it the upstream call.
	return &Proxy{cfg: cfg, quota: quota, client: &http.Client{}, loc: loc, now: time.Now, log: log}
}

func (p *Proxy) Register(mux *http.ServeMux, require func(http.Handler) http.Handler) {
	mux.Handle("GET /v1/llm/models", require(http.HandlerFunc(p.models)))
	mux.Handle("GET /v1/llm/quota", require(http.HandlerFunc(p.quotaStatus)))
	mux.Handle("POST /v1/llm/chat/completions", require(http.HandlerFunc(p.chat)))
}

func (p *Proxy) day() string { return p.now().In(p.loc).Format("2006-01-02") }

// models answers in the OpenAI list shape so the client's connection test works unchanged.
func (p *Proxy) models(w http.ResponseWriter, r *http.Request) {
	type model struct {
		ID      string `json:"id"`
		Object  string `json:"object"`
		OwnedBy string `json:"owned_by"`
	}
	data := make([]model, 0, len(p.cfg.Models))
	for _, m := range p.cfg.Models {
		data = append(data, model{ID: m, Object: "model", OwnedBy: "zhixin"})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"object": "list", "data": data})
}

func (p *Proxy) quotaStatus(w http.ResponseWriter, r *http.Request) {
	pr, _ := auth.PrincipalFrom(r.Context())
	day := p.day()
	used, err := p.quota.Used(r.Context(), pr.UserID, day)
	if err != nil {
		p.internal(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"day": day, "used_tokens": used, "daily_tokens": p.cfg.DailyTokens})
}

// requestHead is the only part of the body the proxy reads.
type requestHead struct {
	Model  string `json:"model"`
	Stream bool   `json:"stream"`
}

func (p *Proxy) chat(w http.ResponseWriter, r *http.Request) {
	pr, _ := auth.PrincipalFrom(r.Context())
	if p.cfg.APIKey == "" {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "model proxy is not configured on this server")
		return
	}
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
	var head requestHead
	if err := json.Unmarshal(body, &head); err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "body is not a JSON object")
		return
	}
	if !slices.Contains(p.cfg.Models, head.Model) {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeModelNotAllowed, "", map[string]any{"models": p.cfg.Models})
		return
	}
	day := p.day()
	used, err := p.quota.Used(r.Context(), pr.UserID, day)
	if err != nil {
		p.internal(w, r, err)
		return
	}
	if used >= p.cfg.DailyTokens {
		httpx.WriteProblemExtra(w, r, http.StatusTooManyRequests, httpx.CodeQuotaExceeded,
			"daily budget used up; use your own key or try again tomorrow",
			map[string]any{"day": day, "used_tokens": used, "daily_tokens": p.cfg.DailyTokens})
		return
	}

	up, err := http.NewRequestWithContext(r.Context(), http.MethodPost, p.cfg.BaseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		p.internal(w, r, err)
		return
	}
	up.Header.Set("Content-Type", "application/json")
	up.Header.Set("Authorization", "Bearer "+p.cfg.APIKey)
	if head.Stream {
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
	if head.Stream {
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

func (p *Proxy) internal(w http.ResponseWriter, r *http.Request, err error) {
	p.log.Error("llm proxy failed", slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
}
