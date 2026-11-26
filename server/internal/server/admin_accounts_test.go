package server

import (
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// TestAdminAccountManagement 在完整装配下核对账号管理的三条路径：搜索与分页、
// 调整额度之后账号自己的额度接口跟着变化，以及注销之后账号、会话与覆盖值一起
// 消失。管理令牌与账号令牌不能互用这一条也在末尾核对。
func TestAdminAccountManagement(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_ADMIN_TOKEN":                testAdminToken,
		"ZHIXIN_LLM_DAILY_TOKENS":           "1000",
		"ZHIXIN_LLM_EMBEDDING_DAILY_TOKENS": "2000",
	})
	admin := func(method, path string, in, out any, want int) {
		t.Helper()
		if code := h.json(method, path, testAdminToken, in, out); code != want {
			t.Fatalf("%s %s: got %d, want %d", method, path, code, want)
		}
	}
	tokenA, idA := h.register("account-a@example.test")
	tokenB, idB := h.register("account-b@example.test")
	h.markContactVerified(idA)

	var list api.AdminAccountList
	admin("GET", "/admin/v1/accounts", nil, &list, http.StatusOK)
	if list.Total != 2 || len(list.Data) != 2 || list.Limit != 20 || list.Offset != 0 {
		t.Fatalf("account list: %+v", list)
	}
	byID := map[string]api.AdminAccount{}
	for _, account := range list.Data {
		byID[account.Id] = account
	}
	a, ok := byID[idA]
	if !ok || len(a.Identities) != 1 || a.Identities[0].Identifier != "account-a@example.test" ||
		!a.Identities[0].Verified || a.Quota.DailyTokens != 1000 ||
		a.Quota.DefaultDailyTokens != 1000 || a.Quota.DailyTokensOverride != nil || a.Usage != nil {
		t.Fatalf("account a: %+v", a)
	}
	if b := byID[idB]; b.Identities[0].Verified {
		t.Fatalf("account b should stay unverified: %+v", b)
	}

	// 搜索按邮箱片段与账号编号都命中，分页参数越界直接拒绝而不是悄悄截断。
	for _, tc := range []struct {
		query string
		id    string
	}{
		{"ACCOUNT-A@", idA},
		{idB[:8], idB},
		{"no-such-user", ""},
	} {
		var found api.AdminAccountList
		admin("GET", "/admin/v1/accounts?query="+url.QueryEscape(tc.query), nil, &found, http.StatusOK)
		if tc.id == "" {
			if found.Total != 0 || len(found.Data) != 0 {
				t.Fatalf("query %q should match nothing: %+v", tc.query, found)
			}
			continue
		}
		if found.Total != 1 || len(found.Data) != 1 || found.Data[0].Id != tc.id {
			t.Fatalf("query %q: %+v", tc.query, found)
		}
	}
	admin("GET", "/admin/v1/accounts?limit=101", nil, nil, http.StatusBadRequest)
	admin("GET", "/admin/v1/accounts?offset=-1", nil, nil, http.StatusBadRequest)

	var detail api.AdminAccount
	admin("GET", "/admin/v1/accounts/"+idA, nil, &detail, http.StatusOK)
	if detail.Id != idA || detail.Usage == nil || detail.Usage.ChatTokens != 0 ||
		detail.Usage.EmbeddingTokens != 0 || detail.Usage.Day.Time.IsZero() {
		t.Fatalf("account detail: %+v", detail)
	}
	// 内存存储没有即刻收：积分一节照常返回，但只说明这个实例没有开通收款，账号
	// 还没有积分余额；列表里不带这一节，避免一页账号逐行查询。
	if detail.Points == nil || detail.Points.Enabled || detail.Points.ChargedToday != 0 ||
		detail.Points.Remaining != nil || detail.Points.SyncedAt != nil || len(detail.Points.Charges) != 0 {
		t.Fatalf("account points without nowpay: %+v", detail.Points)
	}
	if byID[idA].Points != nil {
		t.Fatalf("list should omit points: %+v", byID[idA].Points)
	}
	admin("POST", "/admin/v1/accounts/"+idA+"/points/refresh", nil, nil, http.StatusConflict)
	admin("POST", "/admin/v1/accounts/absent/points/refresh", nil, nil, http.StatusNotFound)
	admin("GET", "/admin/v1/accounts/absent", nil, nil, http.StatusNotFound)

	// 调整聊天额度后，账号自己的额度接口立即读到新值，嵌入仍然走实例默认值。
	var saved api.AdminAccount
	admin("PUT", "/admin/v1/accounts/"+idA+"/quota", map[string]any{
		"daily_tokens": 5000, "note": "内测账号",
	}, &saved, http.StatusOK)
	if saved.Quota.DailyTokens != 5000 || saved.Quota.DailyTokensOverride == nil ||
		*saved.Quota.DailyTokensOverride != 5000 || saved.Quota.Note != "内测账号" ||
		saved.Quota.EmbeddingDailyTokens != 2000 || saved.Quota.EmbeddingDailyTokensOverride != nil {
		t.Fatalf("saved quota: %+v", saved.Quota)
	}
	var quota api.LLMQuota
	if code := h.json("GET", "/v1/llm/quota", tokenA, nil, &quota); code != http.StatusOK {
		t.Fatalf("quota status: %d", code)
	}
	if quota.DailyTokens != 5000 || quota.EmbeddingDailyTokens != 2000 {
		t.Fatalf("effective quota: %+v", quota)
	}
	for _, bad := range []map[string]any{
		{"daily_tokens": 0},
		{"embedding_daily_tokens": -1},
		{"note": strings.Repeat("长", 201)},
		{"unknown": 1},
	} {
		admin("PUT", "/admin/v1/accounts/"+idA+"/quota", bad, nil, http.StatusBadRequest)
	}
	admin("PUT", "/admin/v1/accounts/absent/quota", map[string]any{"daily_tokens": 1}, nil, http.StatusNotFound)

	// 清除覆盖值之后回到实例默认额度，备注一起消失。
	admin("DELETE", "/admin/v1/accounts/"+idA+"/quota", nil, nil, http.StatusNoContent)
	detail = api.AdminAccount{}
	admin("GET", "/admin/v1/accounts/"+idA, nil, &detail, http.StatusOK)
	if detail.Quota.DailyTokens != 1000 || detail.Quota.DailyTokensOverride != nil || detail.Quota.Note != "" {
		t.Fatalf("quota should fall back to the default: %+v", detail.Quota)
	}

	// 注销要求请求体里的编号与路径一致；编号看错时账号必须保留。
	admin("DELETE", "/admin/v1/accounts/"+idA, map[string]string{"user_id": idB}, nil, http.StatusBadRequest)
	if code := h.json("GET", "/v1/me", tokenA, nil, nil); code != http.StatusOK {
		t.Fatalf("account a should survive a mismatched delete: %d", code)
	}
	admin("DELETE", "/admin/v1/accounts/"+idA, map[string]string{"user_id": idA}, nil, http.StatusNoContent)
	admin("DELETE", "/admin/v1/accounts/"+idA, map[string]string{"user_id": idA}, nil, http.StatusNotFound)
	if code := h.json("GET", "/v1/me", tokenA, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("deleted account token should be rejected: %d", code)
	}
	admin("GET", "/admin/v1/accounts", nil, &list, http.StatusOK)
	if list.Total != 1 || len(list.Data) != 1 || list.Data[0].Id != idB {
		t.Fatalf("deleted account should leave the list: %+v", list)
	}

	// 账号令牌不能调用管理接口，管理令牌也不能当作账号令牌使用。
	if code := h.json("GET", "/admin/v1/accounts", tokenB, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("account token reached the admin list: %d", code)
	}
	if code := h.json("GET", "/v1/me", testAdminToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("admin token reached the account API: %d", code)
	}
}
