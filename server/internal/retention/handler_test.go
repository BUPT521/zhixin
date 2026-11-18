package retention

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/testutil"
	"golang.org/x/time/rate"
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) PostV1TelemetryActive(w http.ResponseWriter, r *http.Request) { a.h.Report(w, r) }

func newTestServer(t *testing.T, store Store, limits *ratelimit.Limiter) *testutil.Client {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := NewService(store, []byte("test-secret"), time.UTC)
	svc.now = func() time.Time { return time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC) }
	handler := NewHandler(svc, log, 1<<20, limits, httpx.RemoteHost)
	return testutil.NewClient(t, testutil.NewServer(testAPI{h: handler}, httpx.RequestID))
}

func report(t *testing.T, c *testutil.Client, body any) (int, []byte) {
	t.Helper()
	resp := c.Do(http.MethodPost, "/v1/telemetry/active", "", strings.NewReader(mustJSON(t, body)),
		map[string]string{"Content-Type": "application/json"})
	return resp.StatusCode, testutil.ReadBody(t, resp)
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(b)
}

func TestReportStoresOneRowPerInstallPerDay(t *testing.T) {
	store := NewMemoryStore()
	c := newTestServer(t, store, nil)

	body := map[string]any{
		"install_id":  "0f8fad5b-d9cb-469f-a165-70867728950e",
		"app_version": "0.2.0-dev+3",
		"platform":    "android",
	}
	for i := 0; i < 2; i++ {
		if code, resp := report(t, c, body); code != http.StatusNoContent {
			t.Fatalf("第 %d 次上报应返回 204，得到 %d：%s", i+1, code, resp)
		}
	}
	if got := store.installCount(); got != 1 {
		t.Fatalf("同一标识同一天应只留一行，得到 %d", got)
	}
}

func TestReportKeepsDistinctInstallsApart(t *testing.T) {
	store := NewMemoryStore()
	c := newTestServer(t, store, nil)
	for _, id := range []string{
		"0f8fad5b-d9cb-469f-a165-70867728950e",
		"6ba7b810-9dad-11d1-80b4-00c04fd430c8",
	} {
		if code, resp := report(t, c, map[string]any{"install_id": id}); code != http.StatusNoContent {
			t.Fatalf("上报 %s 应返回 204，得到 %d：%s", id, code, resp)
		}
	}
	if got := store.installCount(); got != 2 {
		t.Fatalf("两个标识应各留一行，得到 %d", got)
	}
}

func TestReportRejectsInvalidInput(t *testing.T) {
	cases := []struct {
		name string
		body map[string]any
	}{
		{"缺安装标识", map[string]any{"platform": "android"}},
		{"安装标识太短", map[string]any{"install_id": "short"}},
		{"安装标识太长", map[string]any{"install_id": strings.Repeat("a", 129)}},
		{"安装标识夹带空格", map[string]any{"install_id": "0f8fad5b d9cb 469f a165 70867728950e"}},
		{"版本太长", map[string]any{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "app_version": strings.Repeat("v", 65)}},
		{"平台太长", map[string]any{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "platform": strings.Repeat("p", 33)}},
		{"未知字段", map[string]any{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e", "date": "2026-11-18"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newTestServer(t, NewMemoryStore(), nil)
			code, body := report(t, c, tc.body)
			if code != http.StatusBadRequest {
				t.Fatalf("应返回 400，得到 %d：%s", code, body)
			}
			var p testutil.Problem
			if err := json.Unmarshal(body, &p); err != nil {
				t.Fatalf("decode problem: %v", err)
			}
			if p.Code != "invalid_request" {
				t.Fatalf("problem code 应为 invalid_request，得到 %q", p.Code)
			}
		})
	}
}

func TestReportStopsAfterRateLimit(t *testing.T) {
	limits := ratelimit.New(rate.Limit(0.001), 1, time.Minute)
	c := newTestServer(t, NewMemoryStore(), limits)
	if code, resp := report(t, c, map[string]any{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e"}); code != http.StatusNoContent {
		t.Fatalf("第一条应被接受，得到 %d：%s", code, resp)
	}
	if code, resp := report(t, c, map[string]any{"install_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8"}); code != http.StatusTooManyRequests {
		t.Fatalf("紧接的一条应被限流，得到 %d：%s", code, resp)
	}
}

// 全局桶与按地址的桶同时生效：地址桶放行时，全局桶用完照样限流。
func TestReportStopsAfterGlobalRateLimit(t *testing.T) {
	c, handler := newTestServerWithHandler(t, NewMemoryStore())
	handler.SetGlobalLimiter(ratelimit.New(rate.Limit(0.001), 1, time.Minute))
	if code, resp := report(t, c, map[string]any{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e"}); code != http.StatusNoContent {
		t.Fatalf("第一条应被接受，得到 %d：%s", code, resp)
	}
	if code, resp := report(t, c, map[string]any{"install_id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8"}); code != http.StatusTooManyRequests {
		t.Fatalf("全局桶用完之后应返回 429，得到 %d：%s", code, resp)
	}
}

// newTestServerWithHandler 与 newTestServer 相同，另外把处理器交给调用方，便于
// 补装配动作，例如设置全局限流器。
func newTestServerWithHandler(t *testing.T, store Store) (*testutil.Client, *Handler) {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc := NewService(store, []byte("test-secret"), time.UTC)
	svc.now = func() time.Time { return time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC) }
	handler := NewHandler(svc, log, 1<<20, nil, httpx.RemoteHost)
	return testutil.NewClient(t, testutil.NewServer(testAPI{h: handler}, httpx.RequestID)), handler
}

// failingStore 模拟数据库写入失败，用来核对处理器把存储故障报成 500。
type failingStore struct{}

func (failingStore) MarkInstallActive(context.Context, string, string, string, string) error {
	return errors.New("db down")
}
func (failingStore) MarkUserActive(context.Context, string, string) error {
	return errors.New("db down")
}
func (failingStore) PruneInstallsBefore(context.Context, string) error {
	return errors.New("db down")
}

func TestReportReportsStoreFailure(t *testing.T) {
	c := newTestServer(t, failingStore{}, nil)
	code, body := report(t, c, map[string]any{"install_id": "0f8fad5b-d9cb-469f-a165-70867728950e"})
	if code != http.StatusInternalServerError {
		t.Fatalf("存储失败应返回 500，得到 %d：%s", code, body)
	}
	var p testutil.Problem
	if err := json.Unmarshal(body, &p); err != nil {
		t.Fatalf("decode problem: %v", err)
	}
	if p.Code != "internal" {
		t.Fatalf("problem code 应为 internal，得到 %q", p.Code)
	}
}
