package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

type syncLog struct {
	q    *db.Queries
	pool *pgxpool.Pool
}

func SyncLog(pool *pgxpool.Pool) syncsvc.Store { return &syncLog{db.New(pool), pool} }

func (s *syncLog) Head(ctx context.Context, userID string) (int64, error) {
	head, err := s.q.SyncHead(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return head, err
}

func (s *syncLog) Append(ctx context.Context, userID string, base int64, commits []syncsvc.Commit) (int64, error) {
	if len(commits) == 0 {
		return s.Head(ctx, userID)
	}
	return inTransaction(ctx, s.pool, func(q *db.Queries) (int64, error) {
		if err := q.EnsureSyncHead(ctx, userID); err != nil {
			return 0, err
		}
		head, err := q.LockSyncHead(ctx, userID)
		if err != nil {
			return 0, err
		}
		ids := make([]string, len(commits))
		for i, c := range commits {
			ids[i] = c.RequestID
		}
		existing, err := q.SeenSyncRequests(ctx, db.SeenSyncRequestsParams{UserID: userID, RequestIds: ids})
		if err != nil {
			return 0, err
		}
		seen := make(map[string]bool, len(existing))
		for _, id := range existing {
			seen[id] = true
		}
		next := head
		for _, c := range commits {
			if seen[c.RequestID] {
				continue
			}
			if base != head {
				return head, syncsvc.ErrHeadMoved
			}
			seen[c.RequestID] = true
			next++
			changes, err := json.Marshal(c.Changes)
			if err != nil {
				return 0, err
			}
			if err := q.InsertSyncCommit(ctx, db.InsertSyncCommitParams{
				UserID: userID, Seq: next, RequestID: c.RequestID, DeviceID: c.DeviceID,
				SchemaVersion: int32(c.SchemaVersion), Actor: c.Actor, Action: c.Action,
				CreatedAt: c.CreatedAt, Changes: changes,
			}); err != nil {
				return 0, err
			}
		}
		if next == head {
			return head, nil
		}
		return next, q.UpdateSyncHead(ctx, db.UpdateSyncHeadParams{UserID: userID, Head: next})
	})
}

func (s *syncLog) After(ctx context.Context, userID string, after int64, limit int) ([]syncsvc.Commit, error) {
	rows, err := s.q.SyncAfter(ctx, db.SyncAfterParams{UserID: userID, Seq: max(0, after), Limit: int32(limit)})
	if err != nil {
		return nil, err
	}
	commits := make([]syncsvc.Commit, 0, len(rows))
	for _, row := range rows {
		c := syncsvc.Commit{
			Seq: row.Seq, RequestID: row.RequestID, DeviceID: row.DeviceID, SchemaVersion: int(row.SchemaVersion),
			Actor: row.Actor, Action: row.Action, CreatedAt: row.CreatedAt, ReceivedAt: row.ReceivedAt.Time,
		}
		if err := json.Unmarshal(row.Changes, &c.Changes); err != nil {
			return nil, err
		}
		commits = append(commits, c)
	}
	return commits, nil
}

func (s *syncLog) DeleteUser(ctx context.Context, userID string) error {
	_, err := inTransaction(ctx, s.pool, func(q *db.Queries) (struct{}, error) {
		if err := q.EnsureSyncHead(ctx, userID); err != nil {
			return struct{}{}, err
		}
		if _, err := q.LockSyncHead(ctx, userID); err != nil {
			return struct{}{}, err
		}
		if err := q.DeleteSyncCommits(ctx, userID); err != nil {
			return struct{}{}, err
		}
		return struct{}{}, q.DeleteSyncHead(ctx, userID)
	})
	return err
}
