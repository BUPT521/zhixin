package pg

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// PurgeStartedAt 返回这个账号的清除标记；没有标记时 ok 为 false。
func (s *Store) PurgeStartedAt(ctx context.Context, userID string) (time.Time, bool, error) {
	started, err := s.q.PurgeStartedAt(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, err
	}
	return started.Time, true, nil
}

// ClaimPurge 在一个语句里取得清除权：没有标记时插入，标记早于 staleBefore 时
// 覆盖，两者都返回一行；标记还新时条件不成立、影响 0 行。并发请求由主键冲突
// 与行锁排队，只有一个拿到 1 行，所以不会两个请求同时从头开始清。
func (s *Store) ClaimPurge(ctx context.Context, userID string, now, staleBefore time.Time) (bool, error) {
	started, err := pgTime(now)
	if err != nil {
		return false, err
	}
	stale, err := pgTime(staleBefore)
	if err != nil {
		return false, err
	}
	claimed, err := s.q.ClaimPurge(ctx, db.ClaimPurgeParams{
		UserID:      userID,
		StartedAt:   started,
		StaleBefore: stale,
	})
	if err != nil {
		return false, err
	}
	return claimed > 0, nil
}

// EndPurge 删除清除标记；成功清除之后调用，下一次清除会重新开始。
func (s *Store) EndPurge(ctx context.Context, userID string) error {
	return s.q.EndPurge(ctx, userID)
}
