package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// TestAPIKeyScopeRevocationAndSharedQuota 在完整装配下核对模型代理密钥的三条
// 规则（ADR-0063）：只作用于 /v1/llm 下的模型接口，额度、并发与“登录方式已
// 验证”的门槛跟账号共用，撤销之后立即失效，删号时一并消失。
func TestAPIKeyScopeRevocationAndSharedQuota(t *testing.T) {
	provider, _ := fakeProvider(t)
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	h.configureModel(provider.URL+"/v1", "zhixin-chat")
	token := h.signUp("apikey@b.cn")

	var created struct {
		ID     string `json:"id"`
		Prefix string `json:"prefix"`
		Key    string `json:"key"`
	}
	if code := h.json("POST", "/v1/me/api-keys", token,
		map[string]string{"name": "脚本", "password": "password1"}, &created); code != http.StatusCreated {
		t.Fatalf("create: %d", code)
	}
	if created.ID == "" || created.Key == "" || created.Prefix == "" {
		t.Fatalf("签发结果不完整：%+v", created)
	}

	// 模型列表只读元数据，不要求登录方式已验证，密钥可以先确认自己能用。
	if code := h.json("GET", "/v1/llm/models", created.Key, nil, nil); code != http.StatusOK {
		t.Fatalf("models with key: %d", code)
	}

	// 托管额度与账号共用同一道验证门槛：账号没有确认过登录方式时，密钥也拿 403。
	var denied problem
	if code := h.json("POST", "/v1/llm/responses", created.Key,
		map[string]any{"model": "zhixin-chat", "input": []any{}}, &denied); code != http.StatusForbidden {
		t.Fatalf("未验证账号用密钥聊天应回 403，得到 %d", code)
	}
	if denied.Code != "contact_unverified" {
		t.Fatalf("错误码应为 contact_unverified，得到 %+v", denied)
	}

	var me struct {
		UserID string `json:"user_id"`
	}
	h.json("GET", "/v1/me", token, nil, &me)
	h.markContactVerified(me.UserID)

	// 密钥的一次聊天记进账号自己的用量，不是另一份额度。
	if code := h.json("POST", "/v1/llm/responses", created.Key,
		map[string]any{"model": "zhixin-chat", "input": []any{}}, nil); code != http.StatusOK {
		t.Fatalf("chat with key: %d", code)
	}
	var quota struct {
		Used int64 `json:"used_tokens"`
	}
	h.json("GET", "/v1/llm/quota", token, nil, &quota)
	if quota.Used != 3 {
		t.Fatalf("账号额度应记入密钥的调用：%+v", quota)
	}

	// 数据接口不在作用域内，回 403 而不是 401：凭据本身有效，只是不允许这一步。
	var scoped problem
	if code := h.json("GET", "/v1/sync/head", created.Key, nil, &scoped); code != http.StatusForbidden {
		t.Fatalf("sync with key: %d", code)
	}
	if scoped.Code != "key_scope_denied" {
		t.Fatalf("错误码应为 key_scope_denied，得到 %+v", scoped)
	}

	// 撤销之后立刻不能再用，重复撤销按找不到处理。
	if code := h.json("DELETE", "/v1/me/api-keys/"+created.ID, token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("revoke: %d", code)
	}
	if code := h.json("GET", "/v1/llm/models", created.Key, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("撤销之后应回 401，得到 %d", code)
	}
	if code := h.json("DELETE", "/v1/me/api-keys/"+created.ID, token, nil, nil); code != http.StatusNotFound {
		t.Fatalf("重复撤销应回 404，得到 %d", code)
	}

	// 撤销全部：两把一起失效，密钥自己不能调用这个接口。
	var batch []struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	}
	for _, name := range []string{"甲", "乙"} {
		var created struct {
			ID  string `json:"id"`
			Key string `json:"key"`
		}
		if code := h.json("POST", "/v1/me/api-keys", token,
			map[string]string{"name": name, "password": "password1"}, &created); code != http.StatusCreated {
			t.Fatalf("create %s: %d", name, code)
		}
		batch = append(batch, created)
	}
	if code := h.json("DELETE", "/v1/me/api-keys", batch[0].Key, nil, nil); code != http.StatusForbidden {
		t.Fatalf("密钥调用撤销全部应回 403，得到 %d", code)
	}
	if code := h.json("DELETE", "/v1/me/api-keys", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("撤销全部：%d", code)
	}
	for _, item := range batch {
		if code := h.json("GET", "/v1/llm/models", item.Key, nil, nil); code != http.StatusUnauthorized {
			t.Fatalf("撤销全部之后密钥应失效，得到 %d", code)
		}
	}

	// 删号之后密钥随账号一起消失。
	var second struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	}
	if code := h.json("POST", "/v1/me/api-keys", token,
		map[string]string{"name": "第二把", "password": "password1"}, &second); code != http.StatusCreated {
		t.Fatalf("create second: %d", code)
	}
	if code := h.json("DELETE", "/v1/me", token, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("delete account: %d", code)
	}
	if code := h.json("GET", "/v1/llm/models", second.Key, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("删号之后密钥应失效，得到 %d", code)
	}
}

// TestAPIKeyFailuresAppearInKeyUsage 在完整装配下核对失败的密钥调用留得下记录：
// 来源拒绝之后 token 记 0、账号额度不动，但后台“按密钥计费”看得到这次尝试与它
// 的失败，而不是显示"所选范围内没有密钥调用记录"（ADR-0083）。
func TestAPIKeyFailuresAppearInKeyUsage(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"error":{"message":"bad"}}`)
	}))
	defer upstream.Close()

	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	h.configureModel(upstream.URL+"/v1", "zhixin-chat")
	token := h.signUp("apikey-fails@b.cn")

	var created struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	}
	if code := h.json("POST", "/v1/me/api-keys", token,
		map[string]string{"name": "脚本", "password": "password1"}, &created); code != http.StatusCreated {
		t.Fatalf("create: %d", code)
	}
	var me struct {
		UserID string `json:"user_id"`
	}
	h.json("GET", "/v1/me", token, nil, &me)
	h.markContactVerified(me.UserID)

	for range 2 {
		if code := h.json("POST", "/v1/llm/responses", created.Key,
			map[string]any{"model": "zhixin-chat", "input": []any{}}, nil); code != http.StatusBadRequest {
			t.Fatalf("上游拒绝时应把 400 交给调用方，得到 %d", code)
		}
	}

	// 失败不扣额度。
	var quota struct {
		Used int64 `json:"used_tokens"`
	}
	h.json("GET", "/v1/llm/quota", token, nil, &quota)
	if quota.Used != 0 {
		t.Fatalf("失败不应扣额度：%+v", quota)
	}

	// 后台按密钥的视图里能看到这两次尝试与两次失败。
	var report api.AdminKeyUsageReport
	if code := h.json("GET", "/admin/v1/key-usage?days=1", testAdminToken, nil, &report); code != http.StatusOK {
		t.Fatalf("key usage: %d", code)
	}
	if len(report.Keys) != 1 {
		t.Fatalf("失败的调用应留下一条按密钥的记录，得到 %d 条：%+v", len(report.Keys), report.Keys)
	}
	row := report.Keys[0]
	if row.KeyId != created.ID || row.Chat.Attempts != 2 || row.Chat.Failures != 2 || row.Chat.Tokens != 0 {
		t.Fatalf("应记 2 次尝试、2 次失败、0 个 token，得到 %+v", row)
	}
}
