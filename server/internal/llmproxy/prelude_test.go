package llmproxy

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// sseEvent 把一个事件写成 SSE 的一行 data；测试里的来源都按这个形状回应。
func sseEvent(payload string) string { return "data: " + payload + "\n\n" }

// newPreludeTestServer 起两条路由的代理：primary 是首条候选，backup 是备用，
// 两者的行为由测试各自写。
func newPreludeTestServer(t *testing.T, cfgFirstOutput time.Duration, primary, backup http.Handler) (*testEnv, *atomic.Int64, *atomic.Int64) {
	t.Helper()
	var primaryHits, backupHits atomic.Int64
	primarySrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		primaryHits.Add(1)
		primary.ServeHTTP(w, r)
	}))
	t.Cleanup(primarySrv.Close)
	backupSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		backupHits.Add(1)
		backup.ServeHTTP(w, r)
	}))
	t.Cleanup(backupSrv.Close)

	cfg := baseConfig()
	cfg.FirstOutputTimeout = cfgFirstOutput
	env := newTestServer(t, cfg, func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "primary", primarySrv.URL, "k1")
		putProvider(t, c, box, "backup", backupSrv.URL, "k2")
		putModel(t, c, ModelRecord{Name: "m", Kind: KindChat, Routes: []Route{
			{ProviderID: "primary", UpstreamModel: "a", Priority: 1},
			{ProviderID: "backup", UpstreamModel: "b", Priority: 2},
		}})
	})
	return env, &primaryHits, &backupHits
}

// streamReply 让备用来源回一条完整的流式回答。
func streamReply(text string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"`+text+`"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.completed","response":{"usage":{"total_tokens":5}}}`))
	})
}

// TestStreamPreludeReasoningBeforeOutput 核对正文之前的思考增量不会被当成
// “首字前的事件太多”而整次换来源。思考型模型在正文之前会连续输出 reasoning
// 增量，开启思考的第三方客户端因此会在每条路由上都撞上旧的 64 KiB 上限。
func TestStreamPreludeReasoningBeforeOutput(t *testing.T) {
	var reasoningHits atomic.Int64
	primary := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		reasoningHits.Add(1)
		w.Header().Set("Content-Type", "text/event-stream")
		filler := strings.Repeat("想", 30)
		// 约 180 KB 的思考增量：超过旧的 64 KiB 上限，在 1 MiB 以内。
		for i := 0; i < 2000; i++ {
			fmt.Fprint(w, sseEvent(`{"type":"response.reasoning_summary_text.delta","delta":"`+filler+`"}`))
		}
		fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"答"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.completed","response":{"usage":{"total_tokens":5}}}`))
	})
	env, _, backupHits := newPreludeTestServer(t, 3*time.Second, primary, streamReply("备"))
	token := signIn(t, env.authSvc, "reasoning-prelude@b.cn")

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(10000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "答") {
		t.Fatalf("首条来源应交付自己的正文，得到 %d %q", resp.StatusCode, body)
	}
	if reasoningHits.Load() != 1 || backupHits.Load() != 0 {
		t.Fatalf("不该换来源，得到 primary=%d backup=%d", reasoningHits.Load(), backupHits.Load())
	}
}

// TestStreamSwitchesAfterOpeningEvents 核对响应头与开场事件之后、首段正文之前
// 上游断开时换下一条候选：客户端只看到备用来源的正文，开场事件不外泄。
func TestStreamSwitchesAfterOpeningEvents(t *testing.T) {
	primary := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, sseEvent(`{"type":"response.created"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.in_progress"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.output_item.added","item":{"type":"message"}}`))
		w.(http.Flusher).Flush()
	})
	env, primaryHits, backupHits := newPreludeTestServer(t, time.Second, primary, streamReply("备"))
	token := signIn(t, env.authSvc, "prelude@b.cn")

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "备") {
		t.Fatalf("应换到备用来源并转发它的正文，得到 %d %q", resp.StatusCode, body)
	}
	if strings.Contains(string(body), "response.created") {
		t.Fatalf("首条候选的开场事件不应转给客户端，得到 %q", body)
	}
	if primaryHits.Load() != 1 || backupHits.Load() != 1 {
		t.Fatalf("每个来源应各尝试一次，得到 primary=%d backup=%d", primaryHits.Load(), backupHits.Load())
	}
}

func TestStreamSwitchesBeforeCompleteOutput(t *testing.T) {
	for _, tc := range []struct {
		name, ending string
		used         int64
	}{
		{"unfinished tool", sseEvent(`{"type":"response.function_call_arguments.delta","delta":"{"}`), 0},
		{"failed", sseEvent(`{"type":"response.failed","response":{"usage":{"total_tokens":7}}}`), 7},
		{"empty completion", sseEvent(`{"type":"response.completed","response":{"usage":{"total_tokens":7}}}`), 7},
	} {
		t.Run(tc.name, func(t *testing.T) {
			primary := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, sseEvent(`{"type":"response.created"}`), tc.ending)
			})
			env, primaryHits, backupHits := newPreludeTestServer(t, time.Second, primary, streamReply("备用正文"))
			usage := NewMemoryUsage()
			env.proxy.SetUsageStore(usage)
			token := signIn(t, env.authSvc, "complete-output@b.cn")
			resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
				bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
			body := testutil.ReadBody(t, resp)
			if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "备用正文") || strings.Contains(string(body), "response.created") {
				t.Fatalf("应只交付备用来源，得到 %d %q", resp.StatusCode, body)
			}
			if primaryHits.Load() != 1 || backupHits.Load() != 1 {
				t.Fatalf("每条来源应尝试一次，得到 primary=%d backup=%d", primaryHits.Load(), backupHits.Load())
			}
			if tc.used > 0 {
				day := env.proxy.day()
				rows, err := usage.RouteUsage(t.Context(), day, day)
				if err != nil || len(rows) != 2 {
					t.Fatalf("应保存两次尝试的用量，得到 %+v，%v", rows, err)
				}
				for _, row := range rows {
					if row.ProviderID == "primary" && (row.Tokens != tc.used || row.FirstAttempts != 1 || row.Successes != 0) {
						t.Fatalf("首发应按上游实际用量结算为失败，得到 %+v", row)
					}
					if row.ProviderID == "backup" && (row.FailoverAttempts != 1 || row.Successes != 1) {
						t.Fatalf("备用尝试应记为切换成功，得到 %+v", row)
					}
				}
			}
		})
	}
}

func TestStreamBindsRouteAfterCompleteToolCall(t *testing.T) {
	primary := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, sseEvent(`{"type":"response.function_call_arguments.delta","delta":"{"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.output_item.done","item":{"type":"function_call","name":"read_material","call_id":"c1","arguments":"{}"}}`))
	})
	env, _, backupHits := newPreludeTestServer(t, time.Second, primary, streamReply("备用正文"))
	token := signIn(t, env.authSvc, "complete-tool@b.cn")
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "read_material") || backupHits.Load() != 0 {
		t.Fatalf("完整工具调用之后应沿用当前来源，得到 %d %q，备用尝试 %d 次", resp.StatusCode, body, backupHits.Load())
	}
}

// TestStreamBindsRouteAfterFirstOutput 核对第一段正文到达之后不再换路：上游随后
// 断开时保留已经显示的正文，不把另一条来源的回答接在同一处。
func TestStreamBindsRouteAfterFirstOutput(t *testing.T) {
	primary := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, sseEvent(`{"type":"response.created"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"半"}`))
		w.(http.Flusher).Flush()
	})
	env, _, backupHits := newPreludeTestServer(t, time.Second, primary, streamReply("备用"))
	token := signIn(t, env.authSvc, "bind@b.cn")

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "半") {
		t.Fatalf("应保留首条候选已经给出的正文，得到 %d %q", resp.StatusCode, body)
	}
	if backupHits.Load() != 0 {
		t.Fatalf("首段正文之后不应再换路，备用来源被调用了 %d 次", backupHits.Load())
	}
}

// TestStreamPreludeTimeoutSwitches 核对只发开场事件、迟迟没有正文的来源在首字
// 时限之后被换掉：等待从发起请求时开始算，响应头早到也不延长它。
func TestStreamPreludeTimeoutSwitches(t *testing.T) {
	primary := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, sseEvent(`{"type":"response.created"}`))
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
		case <-time.After(800 * time.Millisecond):
		}
	})
	env, _, backupHits := newPreludeTestServer(t, 100*time.Millisecond, primary, streamReply("备"))
	token := signIn(t, env.authSvc, "prelude-timeout@b.cn")

	start := time.Now()
	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "备") {
		t.Fatalf("首字时限之后应换到备用来源，得到 %d %q", resp.StatusCode, body)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("首字时限之后应立即换路，实际用了 %v", elapsed)
	}
	if backupHits.Load() != 1 {
		t.Fatalf("备用来源应被调用一次，实际 %d 次", backupHits.Load())
	}
}

// TestCandidatesExhaustedProblem 核对没有任何来源交付有效输出时的返回：502
// upstream_failed，并在 extra.reason 里标明来源已经全部试过，客户端据此进入
// 降级或恢复提示。
func TestCandidatesExhaustedProblem(t *testing.T) {
	// 两条来源都在收到请求之后直接断开：两次尝试都以连接错误结束，最后没有
	// 可以转给客户端的上游状态。
	broken := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
			_ = conn.Close()
		}
	})
	env, primaryHits, backupHits := newPreludeTestServer(t, time.Second, broken, broken)
	token := signIn(t, env.authSvc, "exhausted@b.cn")

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("候选全部失败应回 502，得到 %d", resp.StatusCode)
	}
	problem := testutil.ReadProblem(t, resp)
	if problem.Code != string(httpx.CodeUpstreamFailed) || problem.Extra["reason"] != "candidates_exhausted" {
		t.Fatalf("应标明候选已经耗尽，得到 %+v", problem)
	}
	if primaryHits.Load() != 1 || backupHits.Load() != 1 {
		t.Fatalf("两条候选都应被试过，得到 primary=%d backup=%d", primaryHits.Load(), backupHits.Load())
	}
}

// TestStreamPreludeIsBoundedByBytes 核对开场事件达到暂存上限时换到备用来源。
func TestStreamPreludeIsBoundedByBytes(t *testing.T) {
	const padding = "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
	event := sseEvent(`{"type":"response.created","padding":"` + padding + `"}`)
	// 按当前上限换算条数，上限调整之后用例仍然成立。
	count := maxPreludeBytes/len(event) + 2
	primary := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		for range count {
			fmt.Fprint(w, event)
		}
		flusher.Flush()
		fmt.Fprint(w, sseEvent(`{"type":"response.output_text.delta","delta":"正文"}`))
		fmt.Fprint(w, sseEvent(`{"type":"response.completed","response":{"usage":{"total_tokens":5}}}`))
	})
	env, primaryHits, backupHits := newPreludeTestServer(t, 5*time.Second, primary, streamReply("备用"))
	token := signIn(t, env.authSvc, "prelude-bytes@b.cn")

	resp := env.c.Do(http.MethodPost, "/v1/llm/responses", token,
		bytes.NewReader(chatBody(true)), roundBudgetHeaders(5000))
	body := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "备用") || strings.Contains(string(body), "response.created") {
		t.Fatalf("暂存达到上限后应只交付备用来源，得到 %d %q", resp.StatusCode, body)
	}
	if primaryHits.Load() != 1 || backupHits.Load() != 1 {
		t.Fatalf("达到上限后应尝试备用来源，得到 primary=%d backup=%d", primaryHits.Load(), backupHits.Load())
	}
}
