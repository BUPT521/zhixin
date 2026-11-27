package feedback

import (
	"context"
	"encoding/hex"
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

// testAPI 只接本包的路由；其余路由没有覆盖，被调用时会 panic。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) PostV1Feedback(w http.ResponseWriter, r *http.Request) { a.h.Submit(w, r) }

func newTestServer(t *testing.T, store Store, limits *ratelimit.Limiter) *testutil.Client {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(store), log, 1<<20, limits, httpx.RemoteHost)
	return testutil.NewClient(t, testutil.NewServer(testAPI{h: handler}))
}

func submit(t *testing.T, c *testutil.Client, body any) (int, []byte) {
	t.Helper()
	resp := c.Do(http.MethodPost, "/v1/feedback", "", strings.NewReader(mustJSON(t, body)),
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

func TestSubmitStoresFeedback(t *testing.T) {
	store := NewMemoryStore()
	c := newTestServer(t, store, nil)

	code, body := submit(t, c, map[string]any{
		"content":     "  在记录页按“下一步”没有反应  ",
		"contact":     "Student@Example.COM",
		"app_version": "0.2.0-dev+3",
		"platform":    "android",
		"diagnostics": "2026-11-18 10:00 记录页：点击无响应\n",
	})
	if code != http.StatusCreated {
		t.Fatalf("提交应返回 201，得到 %d：%s", code, body)
	}
	var receipt struct {
		ID        string    `json:"id"`
		CreatedAt time.Time `json:"created_at"`
	}
	if err := json.Unmarshal(body, &receipt); err != nil {
		t.Fatalf("decode receipt: %v", err)
	}
	if len(receipt.ID) != 32 {
		t.Fatalf("回执编号应为 32 位小写十六进制，得到 %q", receipt.ID)
	}
	if _, err := hex.DecodeString(receipt.ID); err != nil {
		t.Fatalf("回执编号不是十六进制：%v", err)
	}
	if receipt.CreatedAt.IsZero() || time.Since(receipt.CreatedAt) > time.Minute {
		t.Fatalf("回执时间不对：%v", receipt.CreatedAt)
	}

	items := store.snapshot()
	if len(items) != 1 {
		t.Fatalf("应保存 1 条反馈，得到 %d", len(items))
	}
	got := items[0]
	if got.ID != receipt.ID {
		t.Fatalf("保存的编号与回执不一致：%q %q", got.ID, receipt.ID)
	}
	if got.Content != "在记录页按“下一步”没有反应" {
		t.Fatalf("正文应去掉两端的空白，得到 %q", got.Content)
	}
	if got.Contact != "student@example.com" {
		t.Fatalf("联系邮箱应转小写，得到 %q", got.Contact)
	}
	if got.AppVersion != "0.2.0-dev+3" || got.Platform != "android" {
		t.Fatalf("版本或平台没有原样保存：%+v", got)
	}
	if got.Diagnostics != "2026-11-18 10:00 记录页：点击无响应" {
		t.Fatalf("诊断摘要没有原样保存：%q", got.Diagnostics)
	}
}

func TestSubmitRejectsInvalidFields(t *testing.T) {
	cases := []struct {
		name string
		body map[string]any
	}{
		{"缺正文", map[string]any{}},
		{"正文只有空白", map[string]any{"content": "   "}},
		{"正文超过 4000 字", map[string]any{"content": strings.Repeat("字", MaxContentRunes+1)}},
		{"联系邮箱不合法", map[string]any{"content": "有问题", "contact": "not-an-email"}},
		{"版本名太长", map[string]any{"content": "有问题", "app_version": strings.Repeat("v", MaxAppVersionRunes+1)}},
		{"平台太长", map[string]any{"content": "有问题", "platform": strings.Repeat("p", MaxPlatformRunes+1)}},
		{"诊断摘要字节过多", map[string]any{"content": "有问题", "diagnostics": strings.Repeat("字", MaxDiagnosticsBytes/3+1)}},
		{"未知字段", map[string]any{"content": "有问题", "screenshot": "base64"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newTestServer(t, NewMemoryStore(), nil)
			code, body := submit(t, c, tc.body)
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

func TestSubmitAcceptsBoundaries(t *testing.T) {
	cases := []map[string]any{
		{"content": strings.Repeat("字", MaxContentRunes)},
		{"content": "x", "diagnostics": strings.Repeat("d", MaxDiagnosticsBytes)},
		{"content": "x", "app_version": strings.Repeat("v", MaxAppVersionRunes), "platform": strings.Repeat("p", MaxPlatformRunes)},
	}
	for i, body := range cases {
		store := NewMemoryStore()
		c := newTestServer(t, store, nil)
		if code, resp := submit(t, c, body); code != http.StatusCreated {
			t.Fatalf("第 %d 组边界值应被接受，得到 %d：%s", i+1, code, resp)
		}
		if len(store.snapshot()) != 1 {
			t.Fatalf("第 %d 组边界值没有保存", i+1)
		}
	}
}

func TestSubmitStopsAfterRateLimit(t *testing.T) {
	limits := ratelimit.New(rate.Limit(0.001), 1, time.Minute)
	c := newTestServer(t, NewMemoryStore(), limits)

	if code, body := submit(t, c, map[string]any{"content": "第一条"}); code != http.StatusCreated {
		t.Fatalf("第一条应被接受，得到 %d：%s", code, body)
	}
	if code, body := submit(t, c, map[string]any{"content": "第二条"}); code != http.StatusTooManyRequests {
		t.Fatalf("紧接的一条应被限流，得到 %d：%s", code, body)
	}
}

// 全局桶与按地址的桶同时生效：地址桶放行时，全局桶用完照样限流。
func TestSubmitStopsAfterGlobalRateLimit(t *testing.T) {
	c, handler := newTestServerWithHandler(t, NewMemoryStore())
	handler.SetGlobalLimiter(ratelimit.New(rate.Limit(0.001), 1, time.Minute))

	if code, body := submit(t, c, map[string]any{"content": "第一条"}); code != http.StatusCreated {
		t.Fatalf("第一条应被接受，得到 %d：%s", code, body)
	}
	if code, body := submit(t, c, map[string]any{"content": "第二条"}); code != http.StatusTooManyRequests {
		t.Fatalf("全局桶用完之后应返回 429，得到 %d：%s", code, body)
	}
}

// newTestServerWithHandler 与 newTestServer 相同，另外把处理器交给调用方，便于
// 补装配动作，例如设置全局限流器。
func newTestServerWithHandler(t *testing.T, store Store) (*testutil.Client, *Handler) {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(store), log, 1<<20, nil, httpx.RemoteHost)
	return testutil.NewClient(t, testutil.NewServer(testAPI{h: handler})), handler
}

// failingStore 模拟数据库写入失败，用来核对处理器把存储故障报成 500，而不是
// 当成用户输入有误。
type failingStore struct{}

func (failingStore) CreateFeedback(context.Context, Item) error { return errors.New("db down") }

func (failingStore) DeleteBefore(context.Context, time.Time) (int64, error) {
	return 0, errors.New("db down")
}

func TestSubmitReportsStoreFailure(t *testing.T) {
	c := newTestServer(t, failingStore{}, nil)
	code, body := submit(t, c, map[string]any{"content": "有问题"})
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
