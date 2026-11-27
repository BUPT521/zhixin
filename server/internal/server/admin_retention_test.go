package server

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// TestAdminRetentionShowsAnonymousAndAccountActivity 核对后台留存视图：需要管理
// 令牌、按区间补零、匿名安装与登录账号分开计数，并且匿名安装的队列留存按首次
// 出现日分组。
func TestAdminRetentionShowsAnonymousAndAccountActivity(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	ctx := context.Background()
	loc := h.cfg.Location
	day := func(offset int) string {
		return time.Now().In(loc).AddDate(0, 0, offset).Format("2006-01-02")
	}

	// 一个安装前天第一次出现、今天回来；另一个安装今天第一次出现。
	for _, row := range []struct{ hash, day string }{
		{"hash-a", day(-2)},
		{"hash-a", day(0)},
		{"hash-b", day(0)},
	} {
		if err := h.stores.Retention.MarkInstallActive(ctx, row.hash, row.day); err != nil {
			t.Fatalf("mark install: %v", err)
		}
	}
	// 注册流程里读了一次 /v1/me，鉴权中间件因此已经记下这个账号今天的活跃。
	h.register("retention@example.test")

	var report api.AdminRetentionReport
	if code := h.json("GET", "/admin/v1/retention?days=7", testAdminToken, nil, &report); code != http.StatusOK {
		t.Fatalf("retention: %d", code)
	}
	if report.Days != 7 || len(report.Daily) != 7 {
		t.Fatalf("应返回 7 天且每天一行，得到 days=%d rows=%d", report.Days, len(report.Daily))
	}
	last := report.Daily[6]
	if last.Day.Time.Format("2006-01-02") != day(0) || last.Installs != 2 || last.Users != 1 {
		t.Fatalf("今天应有两个匿名安装与一个登录账号，得到 %+v", last)
	}
	if first := report.Daily[0]; first.Day.Time.Format("2006-01-02") != day(-6) || first.Installs != 0 {
		t.Fatalf("区间第一天应为空，得到 %+v", first)
	}
	if len(report.Cohorts) != 2 {
		t.Fatalf("前天与今天各有一批首次出现，得到 %+v", report.Cohorts)
	}
	older := report.Cohorts[0]
	if older.FirstDay.Time.Format("2006-01-02") != day(-2) || older.Installs != 1 || older.Returned7d != 1 {
		t.Fatalf("前天的安装今天回来，应算一次一周留存，得到 %+v", older)
	}
	if older.Returned28d != 1 {
		t.Fatalf("一周内回来也在一月之内，得到 %+v", older)
	}
	if newer := report.Cohorts[1]; newer.Installs != 1 || newer.Returned7d != 0 {
		t.Fatalf("今天第一次出现不应算回访，得到 %+v", newer)
	}
}

// TestAdminRetentionRejectsBadInput 核对越界天数与缺少令牌的响应，页面据此显示
// 原因而不是空表。
func TestAdminRetentionRejectsBadInput(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	for _, days := range []string{"0", "-1", "181"} {
		if code := h.json("GET", "/admin/v1/retention?days="+days, testAdminToken, nil, nil); code != http.StatusBadRequest {
			t.Fatalf("days=%s 应返回 400，得到 %d", days, code)
		}
	}
	if code := h.json("GET", "/admin/v1/retention", "", nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("没有管理令牌应返回 401，得到 %d", code)
	}
}

// TestAdminRetentionEmptyInMemoryMode 核对内存模式下不报错：没有活跃数据时每天
// 都补零，队列为空，页面显示“暂无数据”而不是读取失败。
func TestAdminRetentionEmptyInMemoryMode(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	var report api.AdminRetentionReport
	if code := h.json("GET", "/admin/v1/retention", testAdminToken, nil, &report); code != http.StatusOK {
		t.Fatalf("retention: %d", code)
	}
	if report.Days != 30 || len(report.Daily) != 30 || len(report.Cohorts) != 0 {
		t.Fatalf("默认区间应为 30 天且没有队列，得到 days=%d rows=%d cohorts=%d",
			report.Days, len(report.Daily), len(report.Cohorts))
	}
}
