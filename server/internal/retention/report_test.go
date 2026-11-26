package retention

import (
	"context"
	"errors"
	"testing"
	"time"
)

func newTestReporter(store Reader, loc *time.Location, now time.Time) *Reporter {
	reporter := NewReporter(store, loc)
	reporter.now = func() time.Time { return now }
	return reporter
}

// TestReporterFillsDaysAndGroupsCohorts 核对后台报告的三个口径：区间内没有活跃
// 的日期补零、首次当天不算回访、首次出现日早于区间的安装只计入每日活跃而不进
// 队列留存。
func TestReporterFillsDaysAndGroupsCohorts(t *testing.T) {
	store := NewMemoryStore()
	ctx := context.Background()
	for _, row := range []struct {
		hash, day string
	}{
		{"install-a", "2026-11-01"},
		{"install-a", "2026-11-08"}, // 第 7 天回来，算一周留存
		{"install-a", "2026-11-29"}, // 第 28 天回来，算四周留存
		{"install-b", "2026-11-01"},
		{"install-c", "2026-10-31"}, // 早于区间，退出队列，但 11-02 仍算每日活跃
		{"install-c", "2026-11-02"},
	} {
		if err := store.MarkInstallActive(ctx, row.hash, row.day, "0.3.0", "android"); err != nil {
			t.Fatalf("mark install %s %s: %v", row.hash, row.day, err)
		}
	}
	if err := store.MarkUserActive(ctx, "user-1", "2026-11-30"); err != nil {
		t.Fatalf("mark user: %v", err)
	}

	reporter := newTestReporter(store, time.UTC, time.Date(2026, 11, 30, 10, 0, 0, 0, time.UTC))
	report, err := reporter.Report(ctx, 30)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if report.Timezone != "UTC" || report.Days != 30 {
		t.Fatalf("时区或天数不对：%+v", report)
	}
	if len(report.Daily) != 30 {
		t.Fatalf("区间内每天都应有一行，得到 %d", len(report.Daily))
	}
	if report.Daily[0].Day != "2026-11-01" || report.Daily[29].Day != "2026-11-30" {
		t.Fatalf("区间首尾不对：%s 至 %s", report.Daily[0].Day, report.Daily[29].Day)
	}
	if got := report.Daily[0]; got.Installs != 2 || got.Users != 0 {
		t.Fatalf("11-01 应有两个安装、没有登录账号，得到 %+v", got)
	}
	if got := report.Daily[1]; got.Installs != 1 {
		t.Fatalf("11-02 应有一个安装（首次出现在 10-31 也算活跃），得到 %+v", got)
	}
	if got := report.Daily[10]; got.Installs != 0 {
		t.Fatalf("11-11 没有上报，应补零，得到 %+v", got)
	}
	if got := report.Daily[29]; got.Users != 1 {
		t.Fatalf("11-30 应有一个登录账号，得到 %+v", got)
	}

	if len(report.Cohorts) != 1 {
		t.Fatalf("只有 11-01 这一批落在区间内（install-c 首次出现在 10-31），得到 %+v", report.Cohorts)
	}
	first := report.Cohorts[0]
	if first.FirstDay != "2026-11-01" || first.Installs != 2 {
		t.Fatalf("11-01 这一批应有两个安装，得到 %+v", first)
	}
	if first.Returned7d != 1 || first.Returned28d != 1 {
		t.Fatalf("install-a 在第 7 天与第 28 天回来，各算一次：%+v", first)
	}
}

// TestReporterRejectsOutOfRangeDays 核对天数越界时返回可判定的错误，处理器据此
// 返回 400 而不是 500。
func TestReporterRejectsOutOfRangeDays(t *testing.T) {
	reporter := newTestReporter(NewMemoryStore(), time.UTC, time.Date(2026, 11, 30, 10, 0, 0, 0, time.UTC))
	for _, days := range []int{0, -1, ReportMaxDays + 1} {
		if _, err := reporter.Report(context.Background(), days); !errors.Is(err, ErrInvalidRange) {
			t.Fatalf("days=%d 应返回 ErrInvalidRange，得到 %v", days, err)
		}
	}
}

// TestReporterUsesServerDayBoundary 核对自然日按服务端时区切分：UTC 的 11-30
// 16:30 在上海已经是 12-01，区间末行应是 12-01。
func TestReporterUsesServerDayBoundary(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Skipf("缺少时区数据: %v", err)
	}
	store := NewMemoryStore()
	if err := store.MarkInstallActive(context.Background(), "install-a", "2026-12-01", "", ""); err != nil {
		t.Fatalf("mark install: %v", err)
	}
	reporter := newTestReporter(store, loc, time.Date(2026, 11, 30, 16, 30, 0, 0, time.UTC))
	report, err := reporter.Report(context.Background(), 1)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(report.Daily) != 1 || report.Daily[0].Day != "2026-12-01" {
		t.Fatalf("区间应按上海时间落在 12-01，得到 %+v", report.Daily)
	}
	if report.Daily[0].Installs != 1 {
		t.Fatalf("12-01 应有一个安装，得到 %+v", report.Daily[0])
	}
}
