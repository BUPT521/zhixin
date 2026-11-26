package feedback

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestMemoryAdminListSearchesAndPages 核对后台读取的内存实现：按提交时间倒序、
// 关键字覆盖编号、正文、联系邮箱、版本与平台，列表只标出有没有诊断摘要，分页
// 位置越界时返回空页但总数不变。
func TestMemoryAdminListSearchesAndPages(t *testing.T) {
	ctx := context.Background()
	store := NewMemoryStore()
	items := []Item{
		{ID: "a1", Content: "记录页点击没有反应", Contact: "first@example.test",
			AppVersion: "0.2.0-dev+3", Platform: "android",
			CreatedAt: time.Date(2026, 11, 26, 10, 0, 0, 0, time.UTC)},
		{ID: "b2", Content: "希望增加日程导出", Contact: "second@example.test",
			AppVersion: "0.3.0", Platform: "ios", Diagnostics: "设置页截图",
			CreatedAt: time.Date(2026, 11, 26, 11, 0, 0, 0, time.UTC)},
		{ID: "c3", Content: "Semantic search is slow", AppVersion: "0.3.0",
			Platform: "android", CreatedAt: time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)},
	}
	for _, item := range items {
		if err := store.CreateFeedback(ctx, item); err != nil {
			t.Fatalf("seed %s: %v", item.ID, err)
		}
	}

	listed, total, err := store.ListFeedback(ctx, "", 10, 0)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if total != 3 || len(listed) != 3 {
		t.Fatalf("list: total=%d len=%d", total, len(listed))
	}
	if listed[0].ID != "c3" || listed[1].ID != "b2" || listed[2].ID != "a1" {
		t.Fatalf("应按提交时间倒序：%+v", listed)
	}
	if listed[1].HasDiagnostics != true || listed[0].HasDiagnostics != false {
		t.Fatalf("诊断摘要标记不对：%+v", listed)
	}
	if listed[0].Content == "" || listed[0].CreatedAt.IsZero() {
		t.Fatalf("列表字段缺失：%+v", listed[0])
	}

	// 关键字大小写不敏感，字段范围与 PostgreSQL 查询一致。
	for _, tc := range []struct {
		query string
		want  string
	}{
		{"SEMANTIC", "c3"},
		{"second@", "b2"},
		{"0.2.0", "a1"},
		{"IOS", "b2"},
		{"c3", "c3"},
		{"no-such", ""},
	} {
		found, count, err := store.ListFeedback(ctx, tc.query, 10, 0)
		if err != nil {
			t.Fatalf("search %q: %v", tc.query, err)
		}
		if tc.want == "" {
			if count != 0 || len(found) != 0 {
				t.Fatalf("search %q should match nothing: total=%d %+v", tc.query, count, found)
			}
			continue
		}
		if count != 1 || len(found) != 1 || found[0].ID != tc.want {
			t.Fatalf("search %q: total=%d %+v", tc.query, count, found)
		}
	}

	// 分页先取第二条，再取越界位置；总数始终是匹配条数。
	page, total, err := store.ListFeedback(ctx, "", 1, 1)
	if err != nil {
		t.Fatalf("page: %v", err)
	}
	if total != 3 || len(page) != 1 || page[0].ID != "b2" {
		t.Fatalf("page: total=%d %+v", total, page)
	}
	empty, total, err := store.ListFeedback(ctx, "", 10, 3)
	if err != nil {
		t.Fatalf("offset at end: %v", err)
	}
	if total != 3 || len(empty) != 0 {
		t.Fatalf("offset at end: total=%d %+v", total, empty)
	}

	// 读取单条带全文，删除之后列表与总数一起变化，重复删除返回 ErrNotFound。
	full, err := store.FeedbackByID(ctx, "b2")
	if err != nil {
		t.Fatalf("by id: %v", err)
	}
	if full.Diagnostics != "设置页截图" || full.Contact != "second@example.test" {
		t.Fatalf("by id: %+v", full)
	}
	if _, err := store.FeedbackByID(ctx, "absent"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing feedback: %v", err)
	}
	if err := store.DeleteFeedback(ctx, "b2"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if err := store.DeleteFeedback(ctx, "b2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete twice: %v", err)
	}
	if _, total, err = store.ListFeedback(ctx, "", 10, 0); err != nil || total != 2 {
		t.Fatalf("after delete: total=%d err=%v", total, err)
	}
}
