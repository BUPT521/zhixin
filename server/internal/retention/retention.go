// Package retention 记录留存统计所需的活跃数据：登录账号按服务端收到的请求日期
// 记一行，未登录的设备匿名上报安装标识，服务端只保存它的 HMAC-SHA256 与日期。
//
// 采集口径见 ADR-0019：不含学习内容，不保存原始安装标识、IP 与设备编号；匿名
// 数据按 180 天滚动删除。后台的留存视图读同一批数据，见 report.go。
package retention

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

const (
	// ActiveKeepDays 是匿名活跃数据的保留天数，见 ADR-0019 第 4 条。
	ActiveKeepDays = 180
	// DayLayout 是服务端表示自然日的唯一格式。写入时按它落库，读取时按它把日期
	// 转回 time.Time，后台视图直接使用日期值，不再把格式化后的字符串解析一遍。
	DayLayout = "2006-01-02"
	// minInstallRunes 与 maxInstallRunes 限定安装标识的长度，避免客户端把整段
	// 文本或空串当成标识发上来。
	minInstallRunes = 16
	maxInstallRunes = 128
)

// ErrInvalid 表示上报的安装标识不合法。
var ErrInvalid = errors.New("retention: invalid ping")

// Store 保存活跃数据。生产实现写 PostgreSQL；内存实现用于本地开发与测试。
type Store interface {
	// MarkInstallActive 保存一次匿名活跃。同一个安装标识在同一天重复上报只留
	// 一行，交给存储的幂等写入处理。
	MarkInstallActive(ctx context.Context, hash, day string) error
	// MarkUserActive 保存一次登录账号的活跃，同样按天幂等。
	MarkUserActive(ctx context.Context, userID, day string) error
	// PruneInstallsBefore 删除日期早于 before 的匿名活跃行，before 为 YYYY-MM-DD。
	PruneInstallsBefore(ctx context.Context, before string) error
}

// MemoryStore 把活跃数据留在进程内存里，用于本地开发与测试。
type MemoryStore struct {
	mu       sync.Mutex
	installs map[[2]string]struct{} // [哈希, 日期]
	users    map[[2]string]struct{} // [账号, 日期]
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		installs: map[[2]string]struct{}{},
		users:    map[[2]string]struct{}{},
	}
}

func (m *MemoryStore) MarkInstallActive(_ context.Context, hash, day string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.installs[[2]string{hash, day}] = struct{}{}
	return nil
}

func (m *MemoryStore) MarkUserActive(_ context.Context, userID, day string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.users[[2]string{userID, day}] = struct{}{}
	return nil
}

// PruneInstallsBefore 按字符串比较日期，YYYY-MM-DD 的字典序与时间顺序一致。
func (m *MemoryStore) PruneInstallsBefore(_ context.Context, before string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key := range m.installs {
		if key[1] < before {
			delete(m.installs, key)
		}
	}
	return nil
}

// DailyInstallActive 汇总 since 之后每天有上报的安装数，键是自然日。
func (m *MemoryStore) DailyInstallActive(_ context.Context, since string) ([]DayCount, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	counts := make(map[string]int64)
	for key := range m.installs {
		if key[1] >= since {
			counts[key[1]]++
		}
	}
	return dayCounts(counts)
}

// DailyUserActive 汇总 since 之后每天有鉴权请求的账号数。
func (m *MemoryStore) DailyUserActive(_ context.Context, since string) ([]DayCount, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	counts := make(map[string]int64)
	for key := range m.users {
		if key[1] >= since {
			counts[key[1]]++
		}
	}
	return dayCounts(counts)
}

// InstallRetentionCohorts 按第一次出现的日子分组，数一周与四周内再次活跃的
// 安装。内存实现与 SQL 用同一套规则：首次当天不算回访，只有首次出现日不早于
// since 才计入。
func (m *MemoryStore) InstallRetentionCohorts(_ context.Context, since string) ([]Cohort, error) {
	m.mu.Lock()
	days := make(map[string][]string, len(m.installs))
	for key := range m.installs {
		days[key[0]] = append(days[key[0]], key[1])
	}
	m.mu.Unlock()

	byFirst := make(map[string]*Cohort)
	for _, seen := range days {
		first := ""
		for _, day := range seen {
			if first == "" || day < first {
				first = day
			}
		}
		if first == "" || first < since {
			continue
		}
		cohort := byFirst[first]
		if cohort == nil {
			firstDay, err := time.Parse(DayLayout, first)
			if err != nil {
				return nil, err
			}
			cohort = &Cohort{FirstDay: firstDay}
			byFirst[first] = cohort
		}
		cohort.Installs++
		returned7, returned28 := false, false
		for _, day := range seen {
			if day <= first {
				continue
			}
			if withinDays(first, day, 7) {
				returned7 = true
			}
			if withinDays(first, day, 28) {
				returned28 = true
			}
		}
		if returned7 {
			cohort.Returned7d++
		}
		if returned28 {
			cohort.Returned28d++
		}
	}
	out := make([]Cohort, 0, len(byFirst))
	for _, cohort := range byFirst {
		out = append(out, *cohort)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].FirstDay.Before(out[j].FirstDay) })
	return out, nil
}

// withinDays 判断 day 是否落在 first 之后 days 天之内（含第 days 天，不含
// first 当天）。SQL 里是 first_day + days 的比较，这里用同一段时间轴。
func withinDays(first, day string, days int) bool {
	from, err := time.Parse(DayLayout, first)
	if err != nil {
		return false
	}
	to, err := time.Parse(DayLayout, day)
	if err != nil {
		return false
	}
	return !to.After(from.AddDate(0, 0, days))
}

// dayCounts 把日期到数量的映射排成按日期升序的行。
func dayCounts(counts map[string]int64) ([]DayCount, error) {
	out := make([]DayCount, 0, len(counts))
	for day, count := range counts {
		date, err := time.Parse(DayLayout, day)
		if err != nil {
			return nil, err
		}
		out = append(out, DayCount{Day: date, Count: count})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Day.Before(out[j].Day) })
	return out, nil
}

// installCount 与 userDayCount 供本包测试核对保存与清理的结果，后台视图走
// Reader 的读取方法。
func (m *MemoryStore) installCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.installs)
}

func (m *MemoryStore) userDayCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.users)
}

// dayOf 返回 loc 时区下某天对应的自然日，服务端自然日只从这一处取。
func dayOf(t time.Time, loc *time.Location) string {
	return t.In(loc).Format(DayLayout)
}
