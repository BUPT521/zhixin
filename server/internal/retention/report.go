package retention

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"
)

const (
	// ReportMaxDays 是后台一次最多看多少天，与匿名活跃的保留期一致：更早的
	// 行已经被保留期清理删除，再往前看只会得到零。
	ReportMaxDays = ActiveKeepDays
	// ReportDefaultDays 是页面打开时的默认区间，覆盖四周留存所需的观察期。
	ReportDefaultDays = 30
)

// ErrInvalidRange 表示请求的天数超出 1 到 ReportMaxDays。
var ErrInvalidRange = errors.New("retention: days out of range")

// DayCount 是一天的活跃数量；读取层只回有记录的日子，补零由 Reporter 做。
type DayCount struct {
	Day   string
	Count int64
}

// Cohort 是一批第一次出现的匿名安装在一周与四周内的回访数量，回访不含首次
// 当天。
type Cohort struct {
	FirstDay    string
	Installs    int64
	Returned7d  int64
	Returned28d int64
}

// DayActive 是报告里的一天。没有活跃的日期也占一行，数字为 0，页面因此每天
// 都能对齐。
type DayActive struct {
	Day      string
	Installs int64
	Users    int64
}

// Report 是一段区间的活跃与留存。匿名安装既能看每日活跃，也能看按首次出现日
// 分组的留存；登录账号只有每日活跃，它的留存要按账号编号追溯，口径还没定，不
// 在这份报告里给出。
type Report struct {
	Days     int
	Timezone string
	Daily    []DayActive
	Cohorts  []Cohort
}

// Reader 读后台的留存视图。写入路径的 Store 与这里的读取分开：公开上报接口只
// 写，后台视图只读，两者各自实现，测试替身不必同时满足两边。
type Reader interface {
	// DailyInstallActive 返回 since 之后每天有匿名上报的安装数。
	DailyInstallActive(ctx context.Context, since string) ([]DayCount, error)
	// DailyUserActive 返回 since 之后每天有鉴权请求的登录账号数。
	DailyUserActive(ctx context.Context, since string) ([]DayCount, error)
	// InstallRetentionCohorts 返回首次出现日不早于 since 的匿名安装按首次出现
	// 日分组的数量与一周、四周内的回访数量。
	InstallRetentionCohorts(ctx context.Context, since string) ([]Cohort, error)
}

var _ Reader = (*MemoryStore)(nil)

// Reporter 把读取层的行整理成固定天数的报告，缺的日期补零。时区取自
// ZHIXIN_TIMEZONE，与写入时决定自然日的时区一致，否则跨零点的上报会落到另一天。
type Reporter struct {
	reader Reader
	loc    *time.Location
	now    func() time.Time
}

func NewReporter(reader Reader, loc *time.Location) *Reporter {
	if loc == nil {
		loc = time.UTC
	}
	return &Reporter{reader: reader, loc: loc, now: time.Now}
}

// Report 读取包含今天在内、往前 days 天的活跃与留存。区间下界按自然日算，
// 不是按小时往前推，页面上的日期因此与服务端记录的自然日逐日对齐。
func (r *Reporter) Report(ctx context.Context, days int) (Report, error) {
	if days < 1 || days > ReportMaxDays {
		return Report{}, fmt.Errorf("%w: days must be 1 to %d", ErrInvalidRange, ReportMaxDays)
	}
	today := r.now().In(r.loc)
	today = time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, r.loc)
	first := today.AddDate(0, 0, 1-days)
	since := first.Format("2006-01-02")

	installs, err := r.reader.DailyInstallActive(ctx, since)
	if err != nil {
		return Report{}, fmt.Errorf("read daily anonymous activity: %w", err)
	}
	users, err := r.reader.DailyUserActive(ctx, since)
	if err != nil {
		return Report{}, fmt.Errorf("read daily account activity: %w", err)
	}
	cohorts, err := r.reader.InstallRetentionCohorts(ctx, since)
	if err != nil {
		return Report{}, fmt.Errorf("read install retention: %w", err)
	}

	byDay := make(map[string]*DayActive, days)
	for i := range days {
		day := first.AddDate(0, 0, i).Format("2006-01-02")
		byDay[day] = &DayActive{Day: day}
	}
	for _, row := range installs {
		if day, ok := byDay[row.Day]; ok {
			day.Installs = row.Count
		}
	}
	for _, row := range users {
		if day, ok := byDay[row.Day]; ok {
			day.Users = row.Count
		}
	}

	out := Report{
		Days:     days,
		Timezone: r.loc.String(),
		Daily:    make([]DayActive, 0, days),
		Cohorts:  make([]Cohort, 0, len(cohorts)),
	}
	for i := range days {
		day := first.AddDate(0, 0, i).Format("2006-01-02")
		out.Daily = append(out.Daily, *byDay[day])
	}
	for _, cohort := range cohorts {
		// 读取层已经按下界过滤，这里再挡一次：跨保留期被清理的安装不该让某一
		// 天凭空出现在报告里。
		if cohort.FirstDay < since {
			continue
		}
		out.Cohorts = append(out.Cohorts, cohort)
	}
	sort.Slice(out.Cohorts, func(i, j int) bool { return out.Cohorts[i].FirstDay < out.Cohorts[j].FirstDay })
	return out, nil
}
