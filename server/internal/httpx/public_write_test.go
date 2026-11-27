package httpx

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"golang.org/x/time/rate"
)

const publicWriteBody = `{"content":"记录页的“下一步”没有反应"}`

func newPublicWriteRequest(body, remoteAddr string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	req.RemoteAddr = remoteAddr
	return req
}

// decodeProblem 把 problem 响应解出来，核对状态之外的错误码。
func decodeProblem(t *testing.T, rec *httptest.ResponseRecorder) api.Problem {
	t.Helper()
	var p api.Problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode problem: %v；原文 %s", err, rec.Body.String())
	}
	return p
}

func TestPublicWriteStopsAfterAddressLimit(t *testing.T) {
	write := NewPublicWrite(1<<20, ratelimit.New(rate.Limit(0.001), 1, time.Minute), nil)

	var dst map[string]string
	first := httptest.NewRecorder()
	if !write.Decode(first, newPublicWriteRequest(publicWriteBody, "203.0.113.9:1234"), &dst) {
		t.Fatalf("第一条应被接受，得到 %d：%s", first.Code, first.Body.String())
	}

	second := httptest.NewRecorder()
	if write.Decode(second, newPublicWriteRequest(publicWriteBody, "203.0.113.9:1234"), &dst) {
		t.Fatal("同一来源紧接的一条应被限流")
	}
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("应返回 429，得到 %d", second.Code)
	}
	if second.Header().Get("Retry-After") == "" {
		t.Fatal("429 应带上 Retry-After")
	}
	if got := decodeProblem(t, second).Code; got != CodeRateLimited {
		t.Fatalf("problem code 应为 rate_limited，得到 %q", got)
	}
}

// 按来源地址分桶：地址不同就各有一份名额，换地址不会被同一个桶挡住。
func TestPublicWriteKeepsAddressesApart(t *testing.T) {
	write := NewPublicWrite(1<<20, ratelimit.New(rate.Limit(0.001), 1, time.Minute), nil)
	for _, addr := range []string{"203.0.113.9:1234", "198.51.100.1:1234"} {
		rec := httptest.NewRecorder()
		var dst map[string]string
		if !write.Decode(rec, newPublicWriteRequest(publicWriteBody, addr), &dst) {
			t.Fatalf("%s 的第一条应被接受，得到 %d：%s", addr, rec.Code, rec.Body.String())
		}
	}
}

// 全局桶与按地址的桶同时生效：地址桶放行时，全局桶用完照样限流，换地址也绕不过去。
func TestPublicWriteStopsAfterGlobalLimit(t *testing.T) {
	write := NewPublicWrite(1<<20, nil, nil)
	write.SetGlobalLimiter(ratelimit.New(rate.Limit(0.001), 1, time.Minute))

	var dst map[string]string
	first := httptest.NewRecorder()
	if !write.Decode(first, newPublicWriteRequest(publicWriteBody, "203.0.113.9:1234"), &dst) {
		t.Fatalf("第一条应被接受，得到 %d：%s", first.Code, first.Body.String())
	}

	second := httptest.NewRecorder()
	if write.Decode(second, newPublicWriteRequest(publicWriteBody, "198.51.100.1:1234"), &dst) {
		t.Fatal("全局桶用完之后，另一个地址也应被限流")
	}
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("应返回 429，得到 %d", second.Code)
	}
	if got := decodeProblem(t, second).Code; got != CodeRateLimited {
		t.Fatalf("problem code 应为 rate_limited，得到 %q", got)
	}
}

// 限流放行之后的解码口径与 DecodeJSON 一致：正文不合法 400，超过上限 413。
func TestPublicWriteDecodeFailures(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		maxBytes int64
		code     int
		detail   Code
	}{
		{"不是 JSON", `{`, 1 << 20, http.StatusBadRequest, CodeInvalidRequest},
		{"多段 JSON", `{"content":"一"}{"content":"二"}`, 1 << 20, http.StatusBadRequest, CodeInvalidRequest},
		{"超过上限", `{"content":"` + strings.Repeat("字", 64) + `"}`, 32, http.StatusRequestEntityTooLarge, CodePayloadTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			write := NewPublicWrite(tc.maxBytes, nil, nil)
			rec := httptest.NewRecorder()
			var dst map[string]string
			if write.Decode(rec, newPublicWriteRequest(tc.body, "203.0.113.9:1234"), &dst) {
				t.Fatal("不合法的正文不应解码成功")
			}
			if rec.Code != tc.code {
				t.Fatalf("应返回 %d，得到 %d：%s", tc.code, rec.Code, rec.Body.String())
			}
			if got := decodeProblem(t, rec).Code; got != tc.detail {
				t.Fatalf("problem code 应为 %q，得到 %q", tc.detail, got)
			}
		})
	}
}
