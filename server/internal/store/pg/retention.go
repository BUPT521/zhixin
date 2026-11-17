package pg

import (
	"context"

	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// MarkInstallActive 保存一次匿名活跃；同一安装标识同一天重复上报由主键冲突
// 忽略，客户端重试是幂等的。
func (s *Store) MarkInstallActive(ctx context.Context, hash, day, appVersion, platform string) error {
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	return s.q.MarkInstallActive(ctx, db.MarkInstallActiveParams{
		InstallHash: hash,
		Day:         date,
		AppVersion:  appVersion,
		Platform:    platform,
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
