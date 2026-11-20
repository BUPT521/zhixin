package pg

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// State 返回最后一个已分配的序号、保留下界与当前快照指针。
//
// 没有提交序列行的账号按空日志处理：head 为 0，保留下界为 1（没有删除过提交），
// 快照为空；快照缺失不算错误，读取时按没有登记处理（ADR-0043）。
func (s *Store) State(ctx context.Context, userID string) (syncsvc.State, error) {
	state := syncsvc.State{EarliestSeq: 1}
	row, err := s.q.SyncHead(ctx, userID)
	switch {
	case err == nil:
		state.Head = row.Head
		state.EarliestSeq = row.TrimmedThrough + 1
	case !errors.Is(err, pgx.ErrNoRows):
		return state, err
	}
	snap, err := s.q.SyncSnapshot(ctx, userID)
	switch {
	case err == nil:
		state.Snapshot = &syncsvc.Snapshot{
			Seq:       snap.Seq,
			SHA256:    snap.Sha256,
			Digest:    snap.Digest,
			CreatedAt: snap.CreatedAt.Time,
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return state, err
	}
	return state, nil
}

// Append 在一个事务里锁住 sync_head、核对 base 后追加提交。
//
// 已经出现过的 request_id 不再写入；整批都是重放时直接返回当前 head，因为
// 客户端没有收到上一次的响应（与内存实现一致）。追加会让账号超过序列预算时，
// 有快照就先删掉快照位置之前的全部提交再判断，仍然超出才返回 ErrStorageFull
// （ADR-0043）。
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
	locked, err := q.LockSyncHead(ctx, userID)
	if err != nil {
		return 0, err
	}
	head, trimmed := locked.Head, locked.TrimmedThrough

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

	incoming := make([][]byte, len(fresh))
	var metadataBytes int64
	for i, c := range fresh {
		changes, err := json.Marshal(c.Changes)
		if err != nil {
			return 0, err
		}
		incoming[i] = changes
		metadataBytes += int64(len(c.Action) + len(c.RequestId) + len(c.DeviceId) + 256)
	}
	used, err := q.SyncStorageBytes(ctx, userID)
	if err != nil {
		return 0, err
	}
	added, err := q.SyncIncomingBytes(ctx, incoming)
	if err != nil {
		return 0, err
	}
	if used+added+metadataBytes > syncsvc.MaxAccountBytes {
		through, err := compactThroughSnapshot(ctx, q, userID, trimmed)
		if err != nil {
			return head, err
		}
		if through > trimmed {
			trimmed = through
			if used, err = q.SyncStorageBytes(ctx, userID); err != nil {
				return 0, err
			}
		}
		if used+added+metadataBytes > syncsvc.MaxAccountBytes {
			return head, syncsvc.ErrStorageFull
		}
	}
	for i, c := range fresh {
		// 整库摘要可选：客户端只在推送完成、本机没有待推送提交时带上，服务端
		// 原样保存、不解析（改进方案 3.5）。
		stateDigest := pgtype.Text{}
		if c.StateDigest != nil {
			stateDigest = pgtype.Text{String: *c.StateDigest, Valid: true}
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
			Changes:       incoming[i],
			StateDigest:   stateDigest,
		}); err != nil {
			return 0, err
		}
		// 提交身份单独记一份：压缩删掉旧提交之后仍然按它去重（ADR-0043）。
		if err := q.InsertSyncCommitSeen(ctx, db.InsertSyncCommitSeenParams{
			UserID:    userID,
			RequestID: c.RequestId,
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

// compactThroughSnapshot 是预算压力下的压缩：有快照就删掉快照位置之前的全部
// 提交，不按保留期过滤，返回删除到的序号；没有快照或没有可删的提交时返回当前
// 保留下界。调用方已经锁住 sync_head（ADR-0043）。
func compactThroughSnapshot(ctx context.Context, q *db.Queries, userID string, trimmed int64) (int64, error) {
	snap, err := q.SyncSnapshot(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return trimmed, nil
	}
	if err != nil {
		return trimmed, err
	}
	through, err := q.SyncCompactionLimit(ctx, db.SyncCompactionLimitParams{
		UserID:     userID,
		ThroughSeq: snap.Seq,
	})
	if err != nil {
		return trimmed, err
	}
	if through <= trimmed {
		return trimmed, nil
	}
	if err := q.DeleteSyncCommitsThrough(ctx, db.DeleteSyncCommitsThroughParams{
		UserID:     userID,
		ThroughSeq: through,
	}); err != nil {
		return trimmed, err
	}
	if err := q.SetSyncTrimmedThrough(ctx, db.SetSyncTrimmedThroughParams{
		UserID:         userID,
		TrimmedThrough: through,
	}); err != nil {
		return trimmed, err
	}
	return through, nil
}

// RegisterSnapshot 在一个事务里锁住 sync_head，核对位置之后保存快照指针，并按
// 保留期删掉快照覆盖的旧提交。位置比已经保存的旧时返回 ErrSnapshotStale，位置
// 超出 head 时返回 ErrInvalid（ADR-0043）。
func (s *Store) RegisterSnapshot(ctx context.Context, userID string, snap syncsvc.Snapshot, policy syncsvc.CompactPolicy) (syncsvc.State, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return syncsvc.State{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	if err := q.EnsureSyncHead(ctx, userID); err != nil {
		return syncsvc.State{}, err
	}
	locked, err := q.LockSyncHead(ctx, userID)
	if err != nil {
		return syncsvc.State{}, err
	}
	state := syncsvc.State{Head: locked.Head, EarliestSeq: locked.TrimmedThrough + 1}

	current, err := q.SyncSnapshot(ctx, userID)
	switch {
	case err == nil:
		cur := syncsvc.Snapshot{
			Seq:       current.Seq,
			SHA256:    current.Sha256,
			Digest:    current.Digest,
			CreatedAt: current.CreatedAt.Time,
		}
		state.Snapshot = &cur
		if snap.Seq < cur.Seq {
			return state, syncsvc.ErrSnapshotStale
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return syncsvc.State{}, err
	}
	if snap.Seq < 1 || snap.Seq > state.Head {
		return state, syncsvc.ErrInvalid
	}
	if snap.CreatedAt.IsZero() {
		snap.CreatedAt = time.Now().UTC()
	}
	if err := q.UpsertSyncSnapshot(ctx, db.UpsertSyncSnapshotParams{
		UserID:    userID,
		Seq:       snap.Seq,
		Sha256:    snap.SHA256,
		Digest:    snap.Digest,
		CreatedAt: pgtype.Timestamptz{Time: snap.CreatedAt, Valid: true},
	}); err != nil {
		return syncsvc.State{}, err
	}
	// 常规压缩按保留期：快照位置及之前、早于保留窗口的提交删除，让落后不多的
	// 设备继续增量拉取。
	trimmed := state.EarliestSeq - 1
	if policy.Keep > 0 {
		cutoff := time.Now().UTC().Add(-policy.Keep)
		through, err := q.SyncCompactionPoint(ctx, db.SyncCompactionPointParams{
			UserID:     userID,
			ThroughSeq: snap.Seq,
			Cutoff:     pgtype.Timestamptz{Time: cutoff, Valid: true},
		})
		if err != nil {
			return syncsvc.State{}, err
		}
		if through > trimmed {
			if err := q.DeleteSyncCommitsThrough(ctx, db.DeleteSyncCommitsThroughParams{
				UserID:     userID,
				ThroughSeq: through,
			}); err != nil {
				return syncsvc.State{}, err
			}
			if err := q.SetSyncTrimmedThrough(ctx, db.SetSyncTrimmedThroughParams{
				UserID:         userID,
				TrimmedThrough: through,
			}); err != nil {
				return syncsvc.State{}, err
			}
			trimmed = through
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return syncsvc.State{}, err
	}
	stored := snap
	return syncsvc.State{Head: state.Head, EarliestSeq: trimmed + 1, Snapshot: &stored}, nil
}

// Reset 在一个事务里清空账号的提交序列、快照指针、保留下界与去重记录，并把 head
// 重置为 0。
//
// 与 Append 走同一套顺序：先 EnsureSyncHead 保证 head 行存在，再 LockSyncHead 锁住
// 它，删完之后用 ResetSyncHead 写回 0。这样并发的推送要么在锁前完成、要么在重置
// 之后从 0 重新开始，不会把旧序号接着用下去。
func (s *Store) Reset(ctx context.Context, userID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	if err := q.EnsureSyncHead(ctx, userID); err != nil {
		return err
	}
	if _, err := q.LockSyncHead(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncCommits(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncCommitSeen(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncSnapshot(ctx, userID); err != nil {
		return err
	}
	if err := q.ResetSyncHead(ctx, userID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// After 返回 seq 大于 after 的提交，按顺序最多 limit 条。
func (s *Store) After(ctx context.Context, userID string, after int64, limit int, maxBytes int64) ([]syncsvc.Commit, error) {
	rows, err := s.q.CommitsAfter(ctx, db.CommitsAfterParams{
		UserID:    userID,
		AfterSeq:  after,
		PageLimit: int32(limit),
		MaxBytes:  maxBytes,
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
		// 可选摘要原样带回；没有的提交保持为空，客户端据此跳过比较。
		var digest *string
		if row.StateDigest.Valid {
			value := row.StateDigest.String
			digest = &value
		}
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
			StateDigest:   digest,
		})
	}
	return out, nil
}
