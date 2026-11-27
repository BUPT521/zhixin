package llmproxy

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

func TestStreamCompletionControlsUsageAndProbeRecovery(t *testing.T) {
	for _, tc := range []struct {
		name, event string
		phase       healthPhase
		success     int64
		cancel      bool
	}{
		{"completed", `{"type":"response.completed","response":{"usage":{"total_tokens":7}}}`, healthReady, 1, false},
		{"failed", `{"type":"response.failed","response":{"usage":{"total_tokens":7}}}`, healthCooling, 0, false},
		{"incomplete", `{"type":"response.incomplete","response":{"usage":{"total_tokens":7}}}`, healthCooling, 0, false},
		{"output limit", `{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"total_tokens":7}}}`, healthProbeReady, 0, false},
		{"client canceled", `{"type":"response.output_text.delta","delta":"a"}`, healthProbeReady, 0, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				if !tc.cancel {
					fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"a"}`))
				}
				fmt.Fprintf(w, "data: %s\n\n", tc.event)
				if tc.cancel {
					w.(http.Flusher).Flush()
					<-r.Context().Done()
					return
				}
				fmt.Fprint(w, "data: [DONE]\n\n")
			}))
			defer upstream.Close()
			env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
				putProvider(t, c, box, "p", upstream.URL, "test")
				putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
					{ProviderID: "p", UpstreamModel: "a"},
				}})
			})
			usage := NewMemoryUsage()
			env.proxy.SetUsageStore(usage)
			m, _ := env.proxy.router.current().model("m")
			h := env.proxy.router.health
			now := time.Now()
			h.now = func() time.Time { return now }
			for range coolAfterFailures {
				lease, ok := h.acquire(m, m.Live[0], false)
				if !ok {
					t.Fatal("failed to seed cooldown")
				}
				h.complete(lease, false, healthOutcome{reason: "previous failure", scope: routeFailure})
			}
			now = now.Add(coolBase)

			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			ctx = auth.WithPrincipal(ctx, auth.Principal{UserID: "test"})
			req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/v1/llm/responses",
				strings.NewReader(`{"model":"m","input":[],"stream":true}`))
			rec := httptest.NewRecorder()
			var writer http.ResponseWriter = rec
			if tc.cancel {
				writer = cancelOnWrite{rec, cancel}
			}
			env.proxy.Responses(writer, req, RequestOptions{})
			if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), tc.event) {
				t.Fatalf("expected upstream stream, got %d %s", rec.Code, rec.Body.String())
			}
			if got := h.modelViews(m)[0]; got.phase() != tc.phase || got.source.phase != healthReady {
				t.Fatalf("unexpected health: %+v", got)
			}
			day := env.proxy.day()
			rows, err := usage.RouteUsage(t.Context(), day, day)
			var truncated, canceled int64
			if tc.name == "output limit" {
				truncated = 1
			}
			if tc.cancel {
				canceled = 1
			}
			if err != nil || len(rows) != 1 || rows[0].Successes != tc.success || rows[0].FirstAttempts != 1 ||
				rows[0].TruncatedAttempts != truncated || rows[0].CanceledAttempts != canceled || (!tc.cancel && rows[0].Tokens != 7) {
				t.Fatalf("unexpected usage: %+v, %v", rows, err)
			}
		})
	}
}

// TestStreamExceedsResponseBytesStaysHealthy 核对流式响应超过字节上限时的收尾：
// 代理在达到上限时结束这次转发，已经转出的内容照常交给客户端，这次结束不按来源
// 或路由故障计，两者都不累计失败、也不进冷却。
func TestStreamExceedsResponseBytesStaysHealthy(t *testing.T) {
	const limit = 160
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		for range 64 {
			if _, err := fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"a"}`)); err != nil {
				return
			}
			flusher.Flush()
		}
	}))
	defer upstream.Close()

	cfg := baseConfig()
	cfg.MaxResponseBytes = limit
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", upstream.URL, "test")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "p", UpstreamModel: "a"},
		}})
	})
	ctx := auth.WithPrincipal(t.Context(), auth.Principal{UserID: "test"})
	req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/v1/llm/responses",
		strings.NewReader(`{"model":"m","input":[],"stream":true}`))
	rec := httptest.NewRecorder()
	env.proxy.Responses(rec, req, RequestOptions{})

	if rec.Code != http.StatusOK {
		t.Fatalf("流式响应应回 200，得到 %d %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if len(body) == 0 || len(body) > limit {
		t.Fatalf("超过上限时只转发上限之内的内容，得到 %d 字节", len(body))
	}
	if strings.Contains(body, "[DONE]") {
		t.Fatalf("响应被上限截断，不应出现结束标记，得到 %q", body)
	}
	m, _ := env.proxy.router.current().model("m")
	if got := env.proxy.router.health.modelViews(m)[0]; got.phase() != healthReady ||
		got.route.failures != 0 || got.source.failures != 0 {
		t.Fatalf("代理自己的字节上限不应记成来源故障，得到 %+v", got)
	}
}

// TestStreamAtResponseBytesLimitCompletes 核对恰好用完上限的流式响应仍然按正常
// 结束处理：超限要读到上限之外还有内容才成立，正好等于上限的完整回答不能因此被
// 截断或被记成失败。
func TestStreamAtResponseBytesLimitCompletes(t *testing.T) {
	payload := sseEvent(`{"type":"response.output_text.delta","delta":"`+strings.Repeat("a", 40)+`"}`) +
		sseEvent(`{"type":"response.completed","response":{"usage":{"total_tokens":7}}}`) +
		"data: [DONE]\n\n"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, payload)
	}))
	defer upstream.Close()

	cfg := baseConfig()
	cfg.MaxResponseBytes = int64(len(payload))
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "p", upstream.URL, "test")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "p", UpstreamModel: "a"},
		}})
	})
	usage := NewMemoryUsage()
	env.proxy.SetUsageStore(usage)
	ctx := auth.WithPrincipal(t.Context(), auth.Principal{UserID: "test"})
	req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/v1/llm/responses",
		strings.NewReader(`{"model":"m","input":[],"stream":true}`))
	rec := httptest.NewRecorder()
	env.proxy.Responses(rec, req, RequestOptions{})

	if got := rec.Body.String(); got != payload {
		t.Fatalf("恰好等于上限的响应应完整转发，得到 %d 字节：%q", len(got), got)
	}
	m, _ := env.proxy.router.current().model("m")
	if got := env.proxy.router.health.modelViews(m)[0]; got.phase() != healthReady || got.route.failures != 0 {
		t.Fatalf("正常结束的响应不应记成故障，得到 %+v", got)
	}
	day := env.proxy.day()
	rows, err := usage.RouteUsage(t.Context(), day, day)
	if err != nil || len(rows) != 1 || rows[0].Successes != 1 || rows[0].Tokens != 7 {
		t.Fatalf("恰好等于上限的响应应记成一次成功，得到 %+v, %v", rows, err)
	}
}

type cancelOnWrite struct {
	*httptest.ResponseRecorder
	cancel context.CancelFunc
}

func (w cancelOnWrite) Write(b []byte) (int, error) {
	defer w.cancel()
	return w.ResponseRecorder.Write(b)
}
