package llmproxy

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

func TestRecoveryWithRepresentativeRequests(t *testing.T) {
	for _, sample := range []struct {
		name    string
		content []map[string]string
	}{
		{"text", []map[string]string{{"type": "input_text", "text": "证明等式成立"}}},
		{"image", []map[string]string{
			{"type": "input_text", "text": "解释图中的关系"},
			{"type": "input_image", "image_url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII="},
		}},
		{"long material", []map[string]string{{"type": "input_text", "text": strings.Repeat("整理材料里的定义和证明。", 500)}}},
	} {
		t.Run(sample.name, func(t *testing.T) {
			input, err := json.Marshal([]map[string]any{{"type": "message", "role": "user", "content": sample.content}})
			if err != nil {
				t.Fatal(err)
			}
			body, err := json.Marshal(map[string]any{"model": "m", "input": json.RawMessage(input), "stream": true})
			if err != nil {
				t.Fatal(err)
			}
			for _, scenario := range []struct {
				name                       string
				primary, alternate, backup int
				wantAttempts               []string
			}{
				{"healthy", 200, 200, 200, []string{"first"}},
				{"one route unavailable", 503, 200, 200, []string{"first", "alternate"}},
				{"shared credential rejected", 401, 401, 200, []string{"first", "backup"}},
				{"all unavailable", 503, 503, 503, []string{"first", "alternate", "backup"}},
			} {
				t.Run(scenario.name, func(t *testing.T) {
					attempts := make(chan string, len(scenario.wantAttempts)+3)
					upstream := func(statusFor func(string) int) http.HandlerFunc {
						return func(w http.ResponseWriter, r *http.Request) {
							var req struct {
								Model string          `json:"model"`
								Input json.RawMessage `json:"input"`
							}
							if err := json.NewDecoder(r.Body).Decode(&req); err != nil || !bytes.Equal(req.Input, input) {
								t.Errorf("转发应保留原始问题与附件：%v", err)
							}
							attempts <- req.Model
							if status := statusFor(req.Model); status != http.StatusOK {
								w.WriteHeader(status)
								return
							}
							streamReply(req.Model).ServeHTTP(w, r)
						}
					}
					primary := httptest.NewServer(upstream(func(model string) int {
						if model == "first" {
							return scenario.primary
						}
						return scenario.alternate
					}))
					defer primary.Close()
					backup := httptest.NewServer(upstream(func(string) int { return scenario.backup }))
					defer backup.Close()
					cfg := baseConfig()
					cfg.FirstOutputTimeout = time.Second
					cfg.DailyTokens = 100_000
					env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
						putProvider(t, c, box, "primary", primary.URL, "test-primary")
						putProvider(t, c, box, "backup", backup.URL, "test-backup")
						putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
							{ProviderID: "primary", UpstreamModel: "first", Priority: 0, SupportsImages: true},
							{ProviderID: "primary", UpstreamModel: "alternate", Priority: 1, SupportsImages: true},
							{ProviderID: "backup", UpstreamModel: "backup", Priority: 2, SupportsImages: true},
						}})
					})
					token := signIn(t, env.authSvc, "recovery-matrix@example.test")
					resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token, bytes.NewReader(body), roundBudgetHeaders(5000))
					if scenario.backup == http.StatusServiceUnavailable {
						problem := testutil.ReadProblem(t, resp)
						if resp.StatusCode != http.StatusServiceUnavailable || problem.Code != string(httpx.CodeUpstreamFailed) {
							t.Fatalf("所有来源均失败时应返回上游错误，得到 %d %+v", resp.StatusCode, problem)
						}
					} else {
						last := scenario.wantAttempts[len(scenario.wantAttempts)-1]
						got := string(testutil.ReadBody(t, resp))
						if resp.StatusCode != http.StatusOK || !strings.Contains(got, `"delta":"`+last+`"`) || !strings.Contains(got, "response.completed") {
							t.Fatalf("应完整交付来源 %s 的回答，得到 %d %q", last, resp.StatusCode, got)
						}
					}
					got := make([]string, len(attempts))
					for i := range got {
						got[i] = <-attempts
					}
					if !slices.Equal(got, scenario.wantAttempts) {
						t.Fatalf("尝试顺序为 %v，预期 %v", got, scenario.wantAttempts)
					}
				})
			}
		})
	}
}
