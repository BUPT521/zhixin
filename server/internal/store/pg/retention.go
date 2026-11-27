package pg

import (
	"context"

	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// MarkInstallActive 保存一次匿名活跃；同一安装标识同一天重复上报由主键冲突
// 忽略，客户端重试是幂等的。
func (s *Store) MarkInstallActive(ctx context.Context, hash, day string) error {
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	return s.q.MarkInstallActive(ctx, db.MarkInstallActiveParams{
		InstallHash: hash,
		Day:         date,
	})
}

// MarkUserActive 保存一次登录账号的活跃，一个账号一天一行。
func (s *Store) MarkUserActive(ctx context.Context, userID, day string) error {
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	return s.q.MarkUserActive(ctx, db.MarkUserActiveParams{
		UserID: userID,
		Day:    date,
	})
}

// PruneInstallsBefore 删除保留期之外的匿名活跃。登录账号的活跃不在这里清理：
// 它随账号删除级联，行数也很小。
func (s *Store) PruneInstallsBefore(ctx context.Context, before string) error {
	date, err := pgDate(before)
	if err != nil {
		return err
	}
	return s.q.PruneInstallActiveBefore(ctx, date)
}

// DailyInstallActive 按自然日汇总匿名安装数。区间只影响读取，判断自然日的时区
// 在写入时已经定下，这里不再换算。
func (s *Store) DailyInstallActive(ctx context.Context, since string) ([]retention.DayCount, error) {
	date, err := pgDate(since)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.DailyInstallActive(ctx, date)
	if err != nil {
		return nil, err
	}
	out := make([]retention.DayCount, 0, len(rows))
	for _, row := range rows {
		out = append(out, retention.DayCount{Day: row.Day.Time, Count: row.Installs})
	}
	return out, nil
}

// DailyUserActive 按自然日汇总登录账号数。
func (s *Store) DailyUserActive(ctx context.Context, since string) ([]retention.DayCount, error) {
	date, err := pgDate(since)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.DailyUserActive(ctx, date)
	if err != nil {
		return nil, err
	}
	out := make([]retention.DayCount, 0, len(rows))
	for _, row := range rows {
		out = append(out, retention.DayCount{Day: row.Day.Time, Count: row.Users})
	}
	return out, nil
}

// InstallRetentionCohorts 按首次出现日汇总匿名安装的一周与四周回访。
func (s *Store) InstallRetentionCohorts(ctx context.Context, since string) ([]retention.Cohort, error) {
	date, err := pgDate(since)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.InstallRetentionCohorts(ctx, date)
	if err != nil {
		return nil, err
	}
	out := make([]retention.Cohort, 0, len(rows))
	for _, row := range rows {
		out = append(out, retention.Cohort{
			FirstDay: row.FirstDay.Time, Installs: row.Installs,
			Returned7d: row.Returned7d, Returned28d: row.Returned28d,
		})
	}
	return out, nil
}
