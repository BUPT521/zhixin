package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
)

// 本文件是加固清单第 17 条的端到端验收：走完整的 server.New 装配，核对鉴权、
// 刷新重放、会话上限、删号密码、附件配额、云端清除与模型入口这些跨模块规则。
// 各模块内部的边界仍在各自包的测试里。

// register 注册一个账号并返回访问令牌与账号 id。
func (h *harness) register(email string) (token, userID string) {
	h.t.Helper()
	var tokens struct {
		AccessToken string `json:"access_token"`
		Refresh     string `json:"refresh_token"`
	}
	if code := h.json("POST", "/v1/auth/register", "", map[string]string{
		"identifier": email, "password": "password1",
	}, &tokens); code != http.StatusCreated {
		h.t.Fatalf("register %s: %d", email, code)
	}
	var me struct {
		UserID string `json:"user_id"`
	}
	if code := h.json("GET", "/v1/me", tokens.AccessToken, nil, &me); code != http.StatusOK {
		h.t.Fatalf("me: %d", code)
	}
	return tokens.AccessToken, me.UserID
}

// markContactVerified 把账号名下的第一条登录方式标为已确认，等价于用户收到验证码
// 并确认过；用例用它越过验证步骤去核对托管额度与云端写入的门槛。
func (h *harness) markContactVerified(userID string) {
	h.t.Helper()
	store, ok := h.stores.Auth.(*auth.MemoryStore)
	if !ok {
		h.t.Fatalf("memory harness expected, got %T", h.stores.Auth)
	}
	ctx := context.Background()
	identities, err := store.Identities(ctx, userID)
	if err != nil || len(identities) == 0 {
		h.t.Fatalf("identities of %s: %v", userID, err)
	}
	if err := store.SetIdentityVerified(ctx, userID, identities[0].ID, time.Now()); err != nil {
		h.t.Fatalf("mark verified: %v", err)
	}
}

func readProblem(t *testing.T, resp *http.Response) problem {
	t.Helper()
	defer resp.Body.Close()
	var p problem
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decode problem: %v", err)
	}
	return p
}

// TestDeleteAccountRequiresPassword 核对删号要先提交密码：密码错只回
// invalid_credentials 并保留账号，密码对才清空。
func TestDeleteAccountRequiresPassword(t *testing.T) {
	h := newHarness(t, nil)
	token, _ := h.register("delete@b.cn")

	resp := h.do("DELETE", "/v1/me", token, bytes.NewReader(mustJSON(t, map[string]string{"password": "wrong-password"})),
		map[string]string{"Content-Type": "application/json"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("错密码应回 401，得到 %d", resp.StatusCode)
	}
	if p := readProblem(t, resp); p.Code != "invalid_credentials" {
		t.Fatalf("错密码的错误码 = %q", p.Code)
	}
	if code := h.json("GET", "/v1/me", token, nil, nil); code != http.StatusOK {
		t.Fatalf("错密码之后账号应保留，GET /v1/me = %d", code)
	}

	if code := h.json("DELETE", "/v1/me", token, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("对密码应删除账号，得到 %d", code)
	}
	if code := h.json("GET", "/v1/me", token, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("账号删除后访问令牌应失效，得到 %d", code)
	}
}

// TestLoginFailBudgetReturns429 核对按规范化邮箱的失败预算：错误密码用完预算
// 之后，即使密码正确也先回 429，等令牌补回再放行。
func TestLoginFailBudgetReturns429(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_LOGIN_FAIL_RATE":  "0.000001",
		"ZHIXIN_LOGIN_FAIL_BURST": "1",
	})
	h.register("budget@b.cn")

	bad := map[string]string{"identifier": " Budget@B.cn ", "password": "wrong-password"}
	if code := h.json("POST", "/v1/auth/login", "", bad, nil); code != http.StatusUnauthorized {
		t.Fatalf("第一次错误密码应回 401，得到 %d", code)
	}
	// 预算只有一次：第二次尝试在校验密码之前就被挡住，避免继续消耗 Argon2。
	resp := h.do("POST", "/v1/auth/login", "", bytes.NewReader(mustJSON(t, bad)),
		map[string]string{"Content-Type": "application/json"})
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("预算用完后应回 429，得到 %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Retry-After"); got == "" {
		t.Fatal("429 应带 Retry-After")
	}
}

// TestRefreshReplayWithinGraceKeepsSession 核对刷新轮换与固定 60 秒重试宽限：
// 带同一个 request_id 的重试可以再拿一组令牌；不带 request_id 的重放会撤销
// 会话，之后拿到的访问令牌一起失效。
func TestRefreshReplayWithinGraceKeepsSession(t *testing.T) {
	h := newHarness(t, nil)
	type tokenPair struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	var first tokenPair
	if code := h.json("POST", "/v1/auth/register", "", map[string]string{
		"identifier": "grace@b.cn", "password": "password1",
	}, &first); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}

	refresh := func(token, requestID string) (int, tokenPair) {
		t.Helper()
		var out tokenPair
		code := h.json("POST", "/v1/auth/refresh", "", map[string]string{
			"refresh_token": token, "request_id": requestID,
		}, &out)
		return code, out
	}

	code, rotated := refresh(first.RefreshToken, "refresh-1")
	if code != http.StatusOK || rotated.AccessToken == "" {
		t.Fatalf("第一次刷新应成功：%d", code)
	}
	// 原请求重试：同一个 request_id，仍在宽限期内，按重试处理。
	code, retried := refresh(first.RefreshToken, "refresh-1")
	if code != http.StatusOK || retried.AccessToken == "" {
		t.Fatalf("带同 request_id 的重试应成功：%d", code)
	}
	if code := h.json("GET", "/v1/me", retried.AccessToken, nil, nil); code != http.StatusOK {
		t.Fatalf("重试拿到的访问令牌应可用：%d", code)
	}
	// 无法验证为重试：不带 request_id 的重放撤销整个会话。
	if code, _ := refresh(first.RefreshToken, ""); code != http.StatusUnauthorized {
		t.Fatalf("不带 request_id 的重放应被拒绝，得到 %d", code)
	}
	if code := h.json("GET", "/v1/me", retried.AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("重放之后旧访问令牌应失效，得到 %d", code)
	}
}

// TestSessionLimitDropsOldestLogin 核对单账号会话上限：超过上限时最早登录的
// 设备被清掉，它的访问令牌立即失效。
func TestSessionLimitDropsOldestLogin(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_MAX_SESSIONS_PER_USER": "2"})
	var tokens []struct {
		AccessToken string `json:"access_token"`
	}
	credentials := map[string]string{"identifier": "sessions@b.cn", "password": "password1"}
	var registered struct {
		AccessToken string `json:"access_token"`
	}
	if code := h.json("POST", "/v1/auth/register", "", credentials, &registered); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}
	tokens = append(tokens, registered)
	for i := 0; i < 2; i++ {
		var next struct {
			AccessToken string `json:"access_token"`
		}
		if code := h.json("POST", "/v1/auth/login", "", credentials, &next); code != http.StatusOK {
			t.Fatalf("login %d: %d", i+1, code)
		}
		tokens = append(tokens, next)
		// 让 created_at 有先后，删除最旧一条的判定才确定。
		time.Sleep(2 * time.Millisecond)
	}
	if code := h.json("GET", "/v1/me", tokens[0].AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("超过上限后最早会话应失效，得到 %d", code)
	}
	for _, token := range tokens[1:] {
		if code := h.json("GET", "/v1/me", token.AccessToken, nil, nil); code != http.StatusOK {
			t.Fatalf("最新两个会话应继续可用，得到 %d", code)
		}
	}
}

// TestAttachmentAccountQuotaReturnsStorageFull 核对账号附件总量：两个附件合计
// 超过上限时后一个回 413 storage_full，extra 带已用量与上限。
func TestAttachmentAccountQuotaReturnsStorageFull(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_MAX_ATTACHMENT_BYTES":         "10",
		"ZHIXIN_MAX_ACCOUNT_ATTACHMENT_BYTES": "10",
	})
	token, _ := h.register("quota-attach@b.cn")
	put := func(body []byte) *http.Response {
		sum := sha256.Sum256(body)
		return h.do("PUT", "/v1/blobs/"+hex.EncodeToString(sum[:]), token, bytes.NewReader(body), nil)
	}
	if resp := put([]byte("123456")); resp.StatusCode != http.StatusCreated {
		t.Fatalf("第一个附件应保存，得到 %d", resp.StatusCode)
	}
	resp := put([]byte("abcdef"))
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("超过账号总量应回 413，得到 %d", resp.StatusCode)
	}
	p := readProblem(t, resp)
	if p.Code != "storage_full" {
		t.Fatalf("错误码 = %q", p.Code)
	}
	if p.Extra["used_bytes"] != float64(6) || p.Extra["limit_bytes"] != float64(10) {
		t.Fatalf("extra = %+v", p.Extra)
	}
}

// TestCloudPurgeClearsAllCloudData 核对 DELETE /v1/cloud 一次清空备份、提交
// 序列与附件，空账号重复调用也回 204。
func TestCloudPurgeClearsAllCloudData(t *testing.T) {
	h := newHarness(t, nil)
	token, _ := h.register("purge@b.cn")
	if resp := upload(h, token, []byte("zip"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("backup upload: %d", resp.StatusCode)
	}
	if code := h.json("POST", "/v1/sync/commits", token, map[string]any{
		"base_seq": 0,
		"commits": []map[string]any{{
			"uid": "r1", "kind": "write", "device_id": "d1", "schema_version": ClientSchemaVersion,
			"actor": "user", "action": "test", "created_at": "2026-11-18 20:00:00",
			"changes": []map[string]any{{"table": "t", "row_key": "k", "op": "insert", "after": map[string]any{"v": 1}}},
		}},
	}, nil); code != http.StatusOK {
		t.Fatalf("sync push: %d", code)
	}
	body := []byte("attachment")
	sum := sha256.Sum256(body)
	if resp := h.do("PUT", "/v1/blobs/"+hex.EncodeToString(sum[:]), token, bytes.NewReader(body), nil); resp.StatusCode != http.StatusCreated {
		t.Fatalf("blob put: %d", resp.StatusCode)
	}

	for i := 0; i < 2; i++ {
		if code := h.json("DELETE", "/v1/cloud", token, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
			t.Fatalf("第 %d 次清除应回 204，得到 %d", i+1, code)
		}
	}
	var list struct {
		Backups []any `json:"backups"`
	}
	if code := h.json("GET", "/v1/backups", token, nil, &list); code != http.StatusOK || len(list.Backups) != 0 {
		t.Fatalf("清除后不应有备份：%d %+v", code, list)
	}
	var head struct {
		Head int64 `json:"head"`
	}
	if code := h.json("GET", "/v1/sync/head", token, nil, &head); code != http.StatusOK || head.Head != 0 {
		t.Fatalf("清除后 head 应为 0：%d %+v", code, head)
	}
	if resp := h.do("HEAD", "/v1/blobs/"+hex.EncodeToString(sum[:]), token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("清除后附件应不存在，得到 %d", resp.StatusCode)
	}
}

// TestCrossAccountBackupDeleteLeavesOtherAccount 核对备份按账号隔离：B 删不掉
// A 的备份，A 的下载仍然可用。
func TestCrossAccountBackupDeleteLeavesOtherAccount(t *testing.T) {
	h := newHarness(t, nil)
	owner, _ := h.register("owner@b.cn")
	other, _ := h.register("other@b.cn")
	if resp := upload(h, owner, []byte("zip"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload: %d", resp.StatusCode)
	}
	var list struct {
		Backups []struct {
			ID string `json:"id"`
		} `json:"backups"`
	}
	if code := h.json("GET", "/v1/backups", owner, nil, &list); code != http.StatusOK || len(list.Backups) != 1 {
		t.Fatalf("owner list: %d %+v", code, list)
	}
	id := list.Backups[0].ID
	if code := h.json("DELETE", "/v1/backups/"+id, other, nil, nil); code != http.StatusNotFound {
		t.Fatalf("别的账号删除应回 404，得到 %d", code)
	}
	if resp := h.do("GET", "/v1/backups/"+id, owner, nil, nil); resp.StatusCode != http.StatusOK {
		t.Fatalf("owner 仍应能下载，得到 %d", resp.StatusCode)
	}
}

// TestHostedModelNeedsVerifiedContact 核对没有任何已验证登录方式的账号被挡在
// 托管模型之外，确认一种登录方式之后才转发到上游。
func TestHostedModelNeedsVerifiedContact(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":3}}`)
	}))
	t.Cleanup(upstream.Close)

	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	h.configureModel("http://"+upstream.Listener.Addr().String()+"/v1", "deepseek-flash")
	token, userID := h.register("model@b.cn")
	chat := func() (int, problem) {
		resp := h.do("POST", "/v1/llm/responses", token,
			bytes.NewReader(mustJSON(t, map[string]any{"model": "deepseek-flash", "stream": false, "input": []any{}})),
			map[string]string{"Content-Type": "application/json"})
		var p problem
		if resp.StatusCode != http.StatusOK {
			p = readProblem(t, resp)
		} else {
			_ = resp.Body.Close()
		}
		return resp.StatusCode, p
	}
	if code, p := chat(); code != http.StatusForbidden || p.Code != "contact_unverified" {
		t.Fatalf("没有已验证登录方式应回 403 contact_unverified，得到 %d %+v", code, p)
	}
	h.markContactVerified(userID)
	if code, p := chat(); code != http.StatusOK {
		t.Fatalf("验证之后应转发，得到 %d %+v", code, p)
	}
}

// TestHostedModelConcurrencyLimit 核对同一账号的在途托管请求上限：上游阻塞
// 时超出的请求在读取请求体之前就回 429。
func TestHostedModelConcurrencyLimit(t *testing.T) {
	release := make(chan struct{})
	var started sync.WaitGroup
	started.Add(2)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started.Done()
		<-release
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":3}}`)
	}))
	t.Cleanup(upstream.Close)
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})

	h := newHarness(t, map[string]string{
		"ZHIXIN_ADMIN_TOKEN":             testAdminToken,
		"ZHIXIN_LLM_CONCURRENT_PER_USER": "2",
	})
	h.configureModel("http://"+upstream.Listener.Addr().String()+"/v1", "deepseek-flash")
	token, userID := h.register("concurrent@b.cn")
	h.markContactVerified(userID)

	body := mustJSON(t, map[string]any{"model": "deepseek-flash", "stream": false, "input": []any{}})
	var wg sync.WaitGroup
	results := make(chan int, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp := h.do("POST", "/v1/llm/responses", token, bytes.NewReader(body),
				map[string]string{"Content-Type": "application/json"})
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			results <- resp.StatusCode
		}()
	}
	started.Wait()
	time.Sleep(100 * time.Millisecond)
	close(release)
	wg.Wait()
	close(results)

	var ok, limited int
	for code := range results {
		switch code {
		case http.StatusOK:
			ok++
		case http.StatusTooManyRequests:
			limited++
		default:
			t.Fatalf("unexpected status %d", code)
		}
	}
	if ok != 2 || limited != 2 {
		t.Fatalf("并发上限为 2 时应 2 个转发、2 个 429，得到 ok=%d limited=%d", ok, limited)
	}
}
