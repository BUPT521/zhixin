package pg

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// Head 返回最后一个已分配的序号，空日志为 0。
func (s *Store) Head(ctx context.Context, userID string) (int64, error) {
	head, err := s.q.SyncHead(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return head, err
}

// Append 在一个事务里锁住 sync_head、核对 base 后追加提交。
//
// 已经出现过的 request_id 不再写入；整批都是重放时直接返回当前 head，因为
// 客户端没有收到上一次的响应（与内存实现一致）。
func (s *Store) Append(ctx context.Context, userID string, base int64, commits []syncsvc.Commit) (int64, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	if err := q.EnsureSyncHead(ctx, userID); err != nil {
		return 0, err
	}
	head, err := q.LockSyncHead(ctx, userID)
	if err != nil {
		return 0, err
	}

	ids := make([]string, 0, len(commits))
	for _, c := range commits {
		ids = append(ids, c.RequestId)
	}
	existing, err := q.ExistingRequestIDs(ctx, db.ExistingRequestIDsParams{
		UserID:     userID,
		RequestIds: ids,
	})
	if err != nil {
		return 0, err
	}
	seen := make(map[string]bool, len(existing))
	for _, id := range existing {
		seen[id] = true
	}
	fresh, newHead, err := syncsvc.PlanAppend(head, base, commits, seen)
	if err != nil {
		return head, err
	}
	if len(fresh) == 0 {
		return head, nil
	}

	for i, c := range fresh {
		changes, err := json.Marshal(c.Changes)
		if err != nil {
			return 0, err
		}
		if err := q.InsertSyncCommit(ctx, db.InsertSyncCommitParams{
			UserID:        userID,
			Seq:           head + int64(i) + 1,
			RequestID:     c.RequestId,
			DeviceID:      c.DeviceId,
			SchemaVersion: int32(c.SchemaVersion),
			Actor:         string(c.Actor),
			Action:        c.Action,
			CreatedAt:     c.CreatedAt,
			Changes:       changes,
		}); err != nil {
			return 0, err
		}
	}
	if err := q.SetSyncHead(ctx, db.SetSyncHeadParams{UserID: userID, Head: newHead}); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return newHead, nil
}

// After 返回 seq 大于 after 的提交，按顺序最多 limit 条。
func (s *Store) After(ctx context.Context, userID string, after int64, limit int) ([]syncsvc.Commit, error) {
	rows, err := s.q.CommitsAfter(ctx, db.CommitsAfterParams{
		UserID: userID,
		Seq:    after,
		Limit:  int32(limit),
	})
	if err != nil {
		return nil, err
	}
	out := make([]syncsvc.Commit, 0, len(rows))
	for _, row := range rows {
		var changes []syncsvc.Change
		if len(row.Changes) > 0 {
			if err := json.Unmarshal(row.Changes, &changes); err != nil {
				return nil, err
			}
		}
		seq := row.Seq
		received := row.ReceivedAt.Time
		out = append(out, syncsvc.Commit{
			Seq:           &seq,
			RequestId:     row.RequestID,
			DeviceId:      row.DeviceID,
			SchemaVersion: int(row.SchemaVersion),
			Actor:         api.CommitActor(row.Actor),
			Action:        row.Action,
			CreatedAt:     row.CreatedAt,
			ReceivedAt:    &received,
			Changes:       changes,
		})
	}
	return out, nil
}
