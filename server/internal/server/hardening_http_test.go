package server

import (
	"bytes"
	"net/http"
	"slices"
	"testing"
)

// 本文件收本轮加固的验收用例：路由鉴权与上传限流、统一响应头与请求体时限、
// 来源地址分桶。用例经完整的 server.New 装配发请求，检查的是装配与横切规则，
// 各业务包的处理器细节仍在各自的测试里。

// TestHeadOnProtectedRoutesIsUnauthorized 守住 HEAD 不绕过鉴权：标准库的 GET
// 路由也接 HEAD，未带令牌时应当回 401，而不是落进处理器 panic 成 500。
func TestHeadOnProtectedRoutesIsUnauthorized(t *testing.T) {
	h := newHarness(t, nil)
	for _, path := range []string{"/v1/me", "/v1/llm/quota"} {
		resp := h.do(http.MethodHead, path, "", nil, nil)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("HEAD %s：得到 %d，想要 401", path, resp.StatusCode)
		}
		if got := resp.Header.Get("WWW-Authenticate"); got == "" {
			t.Fatalf("HEAD %s：401 应带 WWW-Authenticate", path)
		}
	}
}

// TestEncodedPathsDoNotBypassAuth 守住编码路径不绕过鉴权：net/http 先把路径
// 归一（%6d 还原成 m，. 段参与匹配）再设 r.Pattern，鉴权因此按注册模式判断。
// 未认证请求要么 401，要么在归一后没有匹配到路由而 404，不能落进处理器。
func TestEncodedPathsDoNotBypassAuth(t *testing.T) {
	h := newHarness(t, nil)
	cases := []struct {
		method string
		path   string
		want   []int
	}{
		// %6d 是 m：归一后匹配 GET /v1/me。
		{http.MethodGet, "/v1/%6de", []int{http.StatusUnauthorized}},
		// 归一后是 /v1/backups/..，会落在 GET /v1/backups/{id} 上（{id} 匹配 ".."），
		// 或者在没有匹配到路由时由兜底处理器回 404；两种都要求先鉴权。
		{http.MethodGet, "/v1/backups/%2e%2e", []int{http.StatusUnauthorized, http.StatusNotFound}},
		// 归一后是 /v1/blobs/../..，仍落在 PUT /v1/blobs/{sha256} 上。
		{http.MethodPut, "/v1/blobs/%2e%2e%2f%2e%2e", []int{http.StatusUnauthorized}},
	}
	for _, tc := range cases {
		resp := h.do(tc.method, tc.path, "", nil, nil)
		if !slices.Contains(tc.want, resp.StatusCode) {
			t.Fatalf("%s %s：得到 %d，想要 %v", tc.method, tc.path, resp.StatusCode, tc.want)
		}
	}
}

// TestUnauthenticatedUploadDoesNotConsumeQuota 核对上传限流在鉴权之后：未认证
// 的 PUT /v1/blobs/<64hex> 回 401，且不占用这个账号的上传额度，登录后的第一次
// 上传仍然通过。
func TestUnauthenticatedUploadDoesNotConsumeQuota(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_UPLOAD_RATE":  "0.0001",
		"ZHIXIN_UPLOAD_BURST": "1",
	})
	body := []byte("attachment-bytes")
	path := "/v1/blobs/" + blobSHA(body)

	anonymous := h.do(http.MethodPut, path, "", bytes.NewReader(body), nil)
	if anonymous.StatusCode != http.StatusUnauthorized {
		t.Fatalf("未认证上传：得到 %d，想要 401", anonymous.StatusCode)
	}

	// 令牌桶只有 1 个令牌；如果未认证的那次也扣了令牌，这里会是 429。
	token := h.signUp("upload-quota@b.cn")
	authed := h.do(http.MethodPut, path, token, bytes.NewReader(body), nil)
	if authed.StatusCode != http.StatusCreated {
		t.Fatalf("登录后的第一次上传：得到 %d，想要 201（额度被未认证请求消耗了）", authed.StatusCode)
	}
}

// TestForwardedForFromUntrustedPeerDoesNotSplitBuckets 核对不可信对端伪造
// X-Forwarded-For 仍落同一个桶：测试客户端从 127.0.0.1 连入，配置信任的是另一个
// 网段，所以两封反馈共用按直接对端分的桶，第二次被限流。
func TestForwardedForFromUntrustedPeerDoesNotSplitBuckets(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_FEEDBACK_RATE":   "0.0001",
		"ZHIXIN_FEEDBACK_BURST":  "1",
		"ZHIXIN_TRUSTED_PROXIES": "192.0.2.0/24",
	})
	submit := func(forwardedFor string) int {
		t.Helper()
		resp := h.do(http.MethodPost, "/v1/feedback", "", bytes.NewReader(mustJSON(t, map[string]string{
			"content": "记录页按“下一步”没有反应",
		})), map[string]string{
			"Content-Type":    "application/json",
			"X-Forwarded-For": forwardedFor,
		})
		return resp.StatusCode
	}
	if code := submit("198.51.100.1"); code != http.StatusCreated {
		t.Fatalf("第一封反馈：得到 %d，想要 201", code)
	}
	if code := submit("203.0.113.9"); code != http.StatusTooManyRequests {
		t.Fatalf("换一个伪造头仍应落在同一个桶，得到 %d，想要 429", code)
	}
}
