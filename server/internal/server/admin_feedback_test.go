package server

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/feedback"
)

// TestAdminFeedbackManagement 在完整装配下核对后台的反馈查看：按提交时间倒序
// 列出、关键字覆盖正文与联系邮箱、诊断摘要只在单条里返回、删除之后列表与单条
// 一起消失，以及分页参数越界与账号令牌都不能绕过管理入口。提交时间直接写进
// 内存存储，避免同一毫秒内的两次提交让顺序依赖编号。
func TestAdminFeedbackManagement(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	admin := func(method, path string, out any, want int) {
		t.Helper()
		if code := h.json(method, path, testAdminToken, nil, out); code != want {
			t.Fatalf("%s %s: got %d, want %d", method, path, code, want)
		}
	}

	base := time.Date(2026, 11, 26, 10, 0, 0, 0, time.UTC)
	seeded := []feedback.Item{
		{ID: "a1", Content: "记录页点击没有反应", Contact: "first@example.test",
			AppVersion: "0.2.0-dev+3", Platform: "android", CreatedAt: base},
		{ID: "b2", Content: "希望增加日程导出", Contact: "second@example.test",
			AppVersion: "0.3.0", Platform: "ios", Diagnostics: "设置页截图",
			CreatedAt: base.Add(time.Hour)},
		{ID: "c3", Content: "Semantic search is slow", AppVersion: "0.3.0",
			Platform: "android", CreatedAt: base.Add(2 * time.Hour)},
	}
	for _, item := range seeded {
		if err := h.stores.Feedback.CreateFeedback(context.Background(), item); err != nil {
			t.Fatalf("seed %s: %v", item.ID, err)
		}
	}

	var list api.AdminFeedbackList
	admin("GET", "/admin/v1/feedback", &list, http.StatusOK)
	if list.Total != 3 || len(list.Data) != 3 || list.Limit != 20 || list.Offset != 0 {
		t.Fatalf("feedback list: %+v", list)
	}
	if list.Data[0].Id != "c3" || list.Data[1].Id != "b2" || list.Data[2].Id != "a1" {
		t.Fatalf("feedback order: %+v", list.Data)
	}
	// 没有联系邮箱的一条用空字符串，不是缺失字段。
	if list.Data[0].Contact != "" || !list.Data[1].HasDiagnostics || list.Data[2].HasDiagnostics {
		t.Fatalf("feedback fields: %+v", list.Data)
	}

	// 关键字覆盖正文与联系邮箱，大小写不敏感；分页越界直接拒绝。
	for _, tc := range []struct {
		query string
		want  string
	}{
		{"SEMANTIC", "c3"},
		{"second@", "b2"},
		{"没有这条", ""},
	} {
		var found api.AdminFeedbackList
		admin("GET", "/admin/v1/feedback?query="+url.QueryEscape(tc.query), &found, http.StatusOK)
		if tc.want == "" {
			if found.Total != 0 || len(found.Data) != 0 {
				t.Fatalf("query %q should match nothing: %+v", tc.query, found)
			}
			continue
		}
		if found.Total != 1 || len(found.Data) != 1 || found.Data[0].Id != tc.want {
			t.Fatalf("query %q: %+v", tc.query, found)
		}
	}
	admin("GET", "/admin/v1/feedback?limit=101", nil, http.StatusBadRequest)
	admin("GET", "/admin/v1/feedback?offset=-1", nil, http.StatusBadRequest)

	var page api.AdminFeedbackList
	admin("GET", "/admin/v1/feedback?limit=1&offset=1", &page, http.StatusOK)
	if page.Total != 3 || len(page.Data) != 1 || page.Data[0].Id != "b2" {
		t.Fatalf("feedback page: %+v", page)
	}

	// 诊断摘要只在单条里返回，列表用 has_diagnostics 标记。
	var detail api.AdminFeedbackDetail
	admin("GET", "/admin/v1/feedback/b2", &detail, http.StatusOK)
	if detail.Id != "b2" || detail.Diagnostics != "设置页截图" ||
		detail.Content != "希望增加日程导出" || detail.Contact != "second@example.test" {
		t.Fatalf("feedback detail: %+v", detail)
	}
	var noDiagnostics api.AdminFeedbackDetail
	admin("GET", "/admin/v1/feedback/a1", &noDiagnostics, http.StatusOK)
	if noDiagnostics.Diagnostics != "" {
		t.Fatalf("feedback without diagnostics: %+v", noDiagnostics)
	}
	admin("GET", "/admin/v1/feedback/absent", nil, http.StatusNotFound)

	// 删除之后单条返回 404，列表少一条；重复删除同样返回 404。
	admin("DELETE", "/admin/v1/feedback/b2", nil, http.StatusNoContent)
	admin("GET", "/admin/v1/feedback/b2", nil, http.StatusNotFound)
	admin("DELETE", "/admin/v1/feedback/b2", nil, http.StatusNotFound)
	admin("GET", "/admin/v1/feedback", &list, http.StatusOK)
	if list.Total != 2 {
		t.Fatalf("feedback after delete: %+v", list)
	}

	// 公开提交写入的是同一个存储，后台下一次读取就能看到；提交时间由服务端
	// 取当前时间，因此排在手工种子之后。
	var receipt api.FeedbackReceipt
	if code := h.json("POST", "/v1/feedback", "", map[string]any{
		"content": "后台与公开接口读的是同一张表", "contact": "fourth@example.test",
	}, &receipt); code != http.StatusCreated {
		t.Fatalf("public submit: %d", code)
	}
	admin("GET", "/admin/v1/feedback", &list, http.StatusOK)
	if list.Total != 3 || list.Data[0].Id != receipt.Id {
		t.Fatalf("feedback after public submit: %+v", list)
	}

	// 账号令牌不能读后台反馈。
	token, _ := h.register("reader@example.test")
	if code := h.json("GET", "/admin/v1/feedback", token, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("account token reached the admin feedback list: %d", code)
	}
}
