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
			env.proxy.Responses(writer, req, nil)
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

type cancelOnWrite struct {
	*httptest.ResponseRecorder
	cancel context.CancelFunc
}

func (w cancelOnWrite) Write(b []byte) (int, error) {
	defer w.cancel()
	return w.ResponseRecorder.Write(b)
}
