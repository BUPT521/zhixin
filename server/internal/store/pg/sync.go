package pg

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// State 返回最后一个已分配的序号、保留下界与当前快照指针。
//
// 没有同步状态行的账号按空日志处理：head 为 0，保留下界为 1（没有删除过提交），
// 快照为空；快照缺失不算错误，读取时按没有登记处理（ADR-0043）。
func (s *Store) State(ctx context.Context, userID string) (syncsvc.State, error) {
	state := syncsvc.State{EarliestSeq: 1}
	row, err := s.q.SyncState(ctx, userID)
	switch {
	case err == nil:
		state.Head = row.Head
		state.EarliestSeq = row.TrimmedThrough + 1
		if snap, ok := snapshotFromRow(row.SnapshotSeq, row.SnapshotSha256, row.SnapshotDigest, row.SnapshotCreatedAt); ok {
			state.Snapshot = &snap
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return state, err
	}
	return state, nil
}

// snapshotFromRow 把同步状态行里的四个可空列组成快照指针；四列同时为空表示没有
// 登记过快照。
func snapshotFromRow(seq pgtype.Int8, sha, digest pgtype.Text, createdAt pgtype.Timestamptz) (syncsvc.Snapshot, bool) {
	if !seq.Valid || !sha.Valid || !digest.Valid || !createdAt.Valid {
		return syncsvc.Snapshot{}, false
	}
	return syncsvc.Snapshot{
		Seq:       seq.Int64,
		SHA256:    sha.String,
		Digest:    digest.String,
		CreatedAt: createdAt.Time,
	}, true
}

// Append 在一个事务里锁住 sync_state、核对 base 后追加提交，并在同一个事务里
// 更新设备名册。
//
// 已经出现过的 uid 不再写入，响应里回它在 sync_commit_seen 记下的序号；整批都是
// 重放时直接返回当前 head，因为客户端没有收到上一次的响应（与内存实现一致）。
// 去重只查 sync_commit_seen，sync_commit 不再为 uid 单独建唯一约束（审查 V17）。
// 追加会让账号超过序列预算时，策略允许删除就先删掉快照位置及之前的全部提交再判断，
// 仍然超出才返回 ErrStorageFull（ADR-0043、ADR-0047、ADR-0054）。名册更新与提交
// 同生共死：推送被拒时设备位置不会先走一步（ADR-0048、ADR-0054）。
func (s *Store) Append(ctx context.Context, userID string, base int64, commits []syncsvc.Commit, policy syncsvc.CompactPolicy, roster syncsvc.DeviceRoster) (syncsvc.AppendResult, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return syncsvc.AppendResult{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	if err := q.EnsureSyncState(ctx, userID); err != nil {
		return syncsvc.AppendResult{}, err
	}
	locked, err := q.LockSyncState(ctx, userID)
	if err != nil {
		return syncsvc.AppendResult{}, err
	}
	head, trimmed := locked.Head, locked.TrimmedThrough
	replayed := syncsvc.AppendResult{Head: head}

	uids := make([]string, 0, len(commits))
	for _, c := range commits {
		uids = append(uids, c.Uid)
	}
	rows, err := q.ExistingCommitSeqs(ctx, db.ExistingCommitSeqsParams{UserID: userID, Uids: uids})
	if err != nil {
		return replayed, err
	}
	seen := make(map[string]int64, len(rows))
	for _, row := range rows {
		seen[row.IdsUid] = row.Seq
	}
	plan, err := syncsvc.PlanAppend(head, base, commits, seen)
	if err != nil {
		return replayed, err
	}
	if plan.AllDuplicates() {
		if err := applyDeviceRoster(ctx, q, userID, roster, base, head, false); err != nil {
			return replayed, err
		}
		if err := tx.Commit(ctx); err != nil {
			return replayed, err
		}
		replayed.Seqs = plan.Seqs
		return replayed, nil
	}
	fresh := plan.Fresh

	incoming := make([][]byte, len(fresh))
	var metadataBytes int64
	for i, c := range fresh {
		changes, err := json.Marshal(c.Changes)
		if err != nil {
			return replayed, err
		}
		incoming[i] = changes
		metadataBytes += int64(len(c.Action) + len(c.Uid) + len(c.DeviceId) + len(c.Kind) + 256)
	}
	used, err := q.SyncStorageBytes(ctx, userID)
	if err != nil {
		return replayed, err
	}
	added, err := q.SyncIncomingBytes(ctx, incoming)
	if err != nil {
		return replayed, err
	}
	if used+added+metadataBytes > syncsvc.MaxAccountBytes {
		if !policy.AllowDelete {
			return replayed, syncsvc.ErrStorageFull
		}
		through, err := compactThroughSnapshot(ctx, q, userID, trimmed)
		if err != nil {
			return replayed, err
		}
		if through > trimmed {
			trimmed = through
			if used, err = q.SyncStorageBytes(ctx, userID); err != nil {
				return replayed, err
			}
		}
		if used+added+metadataBytes > syncsvc.MaxAccountBytes {
			return replayed, syncsvc.ErrStorageFull
		}
	}
	for i, c := range fresh {
		seq := plan.FreshSeqs[i]
		if err := q.InsertSyncCommit(ctx, db.InsertSyncCommitParams{
			UserID:        userID,
			Seq:           seq,
			Uid:           c.Uid,
			Kind:          string(c.Kind),
			DeviceID:      c.DeviceId,
			SchemaVersion: int32(c.SchemaVersion),
			Actor:         string(c.Actor),
			Action:        c.Action,
			CreatedAt:     c.CreatedAt,
			Changes:       incoming[i],
			StateDigest:   optionalText(c.StateDigest),
			TableDigests:  tableDigestsJSON(c.TableDigests),
		}); err != nil {
			return replayed, err
		}
		// 提交身份与这次分配的序号单独记一份：压缩删掉旧提交之后仍然按它去重，
		// 整批重放也能回出原序号（ADR-0043、ADR-0054）。
		if err := q.InsertSyncCommitSeen(ctx, db.InsertSyncCommitSeenParams{
			UserID: userID,
			Uid:    c.Uid,
			Seq:    seq,
		}); err != nil {
			return replayed, err
		}
	}
	if err := q.SetSyncHead(ctx, db.SetSyncHeadParams{UserID: userID, Head: plan.NewHead}); err != nil {
		return replayed, err
	}
	if err := applyDeviceRoster(ctx, q, userID, roster, base, plan.NewHead, true); err != nil {
		return replayed, err
	}
	if err := tx.Commit(ctx); err != nil {
		return replayed, err
	}
	return syncsvc.AppendResult{Head: plan.NewHead, Seqs: plan.Seqs}, nil
}

// applyDeviceRoster 在 Append 的事务里写设备名册：请求带设备标识时把这一台的
// 位置推进到 base（有新提交时取新 head），否则按提交里出现的设备标识补行。
func applyDeviceRoster(ctx context.Context, q *db.Queries, userID string, roster syncsvc.DeviceRoster, base, head int64, fresh bool) error {
	if roster.Touch != nil {
		position := base
		if fresh {
			position = max(position, head)
		}
		return q.TouchSyncDevice(ctx, db.TouchSyncDeviceParams{
			UserID:          userID,
			DeviceID:        roster.Touch.DeviceID,
			SnapshotCapable: roster.Touch.SnapshotCapable,
			SyncedSeq:       position,
			Head:            head,
		})
	}
	for _, deviceID := range roster.Ensure {
		if err := q.EnsureSyncDevice(ctx, db.EnsureSyncDeviceParams{UserID: userID, DeviceID: deviceID}); err != nil {
			return err
		}
	}
	return nil
}

// optionalText 把可空的文本摘要写成 NULL 或者值。
func optionalText(value *string) pgtype.Text {
	if value == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *value, Valid: true}
}

// tableDigestsJSON 把可空的分表摘要编码成 JSONB；没有带的提交存 NULL，响应里也就
// 不会出现这个键（ADR-0054）。
func tableDigestsJSON(value *map[string]string) []byte {
	if value == nil {
		return nil
	}
	b, err := json.Marshal(*value)
	if err != nil {
		// 值来自契约里的 map[string]string，编码不会失败；真出错时按没有带来处理，
		// 不让一条摘要挡下整批提交。
		return nil
	}
	return b
}

// compactThroughSnapshot 是预算压力下的压缩：有快照就删掉快照位置及之前的全部
// 提交，不按保留期与设备位置过滤，返回删除到的序号；没有快照或没有可删的提交时
// 返回当前保留下界。调用方已经锁住 sync_state（ADR-0043、ADR-0054）。
func compactThroughSnapshot(ctx context.Context, q *db.Queries, userID string, trimmed int64) (int64, error) {
	state, err := q.SyncState(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return trimmed, nil
	}
	if err != nil {
		return trimmed, err
	}
	if _, ok := snapshotFromRow(state.SnapshotSeq, state.SnapshotSha256, state.SnapshotDigest, state.SnapshotCreatedAt); !ok {
		return trimmed, nil
	}
	through, err := q.SyncCompactionLimit(ctx, db.SyncCompactionLimitParams{
		UserID:     userID,
		ThroughSeq: state.SnapshotSeq.Int64,
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

// RegisterSnapshot 在一个事务里锁住 sync_state，核对位置之后保存快照指针，把让位
// 的旧哈希标记成待回收，并在策略允许时按保留期与设备位置删掉快照覆盖的旧提交。
// 位置比已经保存的旧时返回 ErrSnapshotStale，位置超出 head 时返回 ErrInvalid
// （ADR-0043、ADR-0047、ADR-0054）。
func (s *Store) RegisterSnapshot(ctx context.Context, userID string, snap syncsvc.Snapshot, policy syncsvc.CompactPolicy) (syncsvc.State, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return syncsvc.State{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	if err := q.EnsureSyncState(ctx, userID); err != nil {
		return syncsvc.State{}, err
	}
	locked, err := q.LockSyncState(ctx, userID)
	if err != nil {
		return syncsvc.State{}, err
	}
	out := syncsvc.State{Head: locked.Head, EarliestSeq: locked.TrimmedThrough + 1}
	current, hasSnapshot := snapshotFromRow(locked.SnapshotSeq, locked.SnapshotSha256, locked.SnapshotDigest, locked.SnapshotCreatedAt)
	if hasSnapshot {
		cur := current
		out.Snapshot = &cur
	}
	// 先判位置是否落在 1..head，再判是否比已存指针旧：两个存储按同一顺序检查，
	// seq=0 这类既越界又可能被看成“旧位置”的输入因此都回 ErrInvalid。
	if snap.Seq < 1 || snap.Seq > out.Head {
		return out, syncsvc.ErrInvalid
	}
	if hasSnapshot && snap.Seq < current.Seq {
		return out, syncsvc.ErrSnapshotStale
	}
	if snap.CreatedAt.IsZero() {
		snap.CreatedAt = time.Now().UTC()
	}
	// 新指针重新使用一个待回收的哈希时清掉它的标记；旧指针重新在使用时同样清掉，
	// 指针换回来之后两份附件都还在使用（ADR-0047 第 1 条）。
	currentPointers := make([]string, 0, 1)
	if hasSnapshot {
		currentPointers = append(currentPointers, current.SHA256)
	}
	if err := q.ClearAttachmentOrphaned(ctx, db.ClearAttachmentOrphanedParams{
		UserID:         userID,
		Sha256:         snap.SHA256,
		CurrentSha256s: currentPointers,
	}); err != nil {
		return syncsvc.State{}, err
	}
	// 旧指针让位时把旧哈希那一行标记成待回收，同一哈希重复让位保留最早的时间。
	if hasSnapshot && current.SHA256 != "" && current.SHA256 != snap.SHA256 {
		if err := q.MarkAttachmentOrphaned(ctx, db.MarkAttachmentOrphanedParams{
			UserID: userID,
			Sha256: current.SHA256,
		}); err != nil {
			return syncsvc.State{}, err
		}
	}
	if err := q.UpsertSyncSnapshot(ctx, db.UpsertSyncSnapshotParams{
		UserID:            userID,
		SnapshotSeq:       pgtype.Int8{Int64: snap.Seq, Valid: true},
		SnapshotSha256:    pgtype.Text{String: snap.SHA256, Valid: true},
		SnapshotDigest:    pgtype.Text{String: snap.Digest, Valid: true},
		SnapshotCreatedAt: pgtype.Timestamptz{Time: snap.CreatedAt, Valid: true},
	}); err != nil {
		return syncsvc.State{}, err
	}
	// 常规压缩按保留期与设备位置：快照位置及之前、早于保留窗口、且不越过
	// policy.DeviceFloor 的提交删除，让落后不多的设备继续增量拉取。策略不允许删除
	// 时只写指针（ADR-0047 第 3 条、ADR-0054 第 3 条）。
	trimmed := out.EarliestSeq - 1
	if policy.AllowDelete && policy.Keep > 0 {
		cutoff := time.Now().UTC().Add(-policy.Keep)
		through, err := q.SyncCompactionPoint(ctx, db.SyncCompactionPointParams{
			UserID:     userID,
			ThroughSeq: snap.Seq,
			FloorSeq:   policy.DeviceFloor,
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
	return syncsvc.State{Head: out.Head, EarliestSeq: trimmed + 1, Snapshot: &stored}, nil
}

// Reset 在一个事务里清空账号的提交序列、去重记录、快照指针、保留下界、设备名册与
// 命名版本，清掉本账号附件的回收标记，并把 head 重置为 0。
//
// 与 Append 走同一套顺序：先 EnsureSyncState 保证状态行存在，再 LockSyncState 锁住
// 它，删完之后用 ResetSyncState 写回 0。这样并发的推送要么在锁前完成、要么在重置
// 之后从 0 重新开始，不会把旧序号接着用下去。
func (s *Store) Reset(ctx context.Context, userID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.q.WithTx(tx)

	if err := q.EnsureSyncState(ctx, userID); err != nil {
		return err
	}
	if _, err := q.LockSyncState(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncCommits(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncCommitSeen(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncDevices(ctx, userID); err != nil {
		return err
	}
	if err := q.DeleteSyncRefs(ctx, userID); err != nil {
		return err
	}
	// 附件与附件索引由附件存储另行清；这里只清掉待回收标记。
	if err := q.ClearAttachmentsOrphaned(ctx, userID); err != nil {
		return err
	}
	if err := q.ResetSyncState(ctx, userID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ---- 旧快照附件回收与设备名册（ADR-0047、ADR-0048、ADR-0054） ----

// OrphanedAttachmentsBefore 列出让位时间早于 before 的哈希，排除当前快照指针。
func (s *Store) OrphanedAttachmentsBefore(ctx context.Context, userID string, before time.Time) ([]string, error) {
	at, err := pgTime(before)
	if err != nil {
		return nil, err
	}
	state, err := s.q.SyncState(ctx, userID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	current := pgtype.Text{}
	if snap, ok := snapshotFromRow(state.SnapshotSeq, state.SnapshotSha256, state.SnapshotDigest, state.SnapshotCreatedAt); ok {
		current = pgtype.Text{String: snap.SHA256, Valid: true}
	}
	return s.q.AttachmentsOrphanedBefore(ctx, db.AttachmentsOrphanedBeforeParams{
		UserID:        userID,
		Before:        at,
		CurrentSha256: current,
	})
}

// ReclaimOrphan 回收一份旧快照附件：先删对象存储里的字节（不存在按已删除处理），
// 再删附件索引行。任一步失败都保留索引行，下一轮登记再试（ADR-0047）。
func (s *Store) ReclaimOrphan(ctx context.Context, userID, sha string) error {
	if err := s.objects.Remove(ctx, objectstore.AttachmentKey(userID, sha)); err != nil {
		return err
	}
	_, err := s.q.DeleteAttachment(ctx, db.DeleteAttachmentParams{UserID: userID, Sha256: sha})
	return err
}

// TouchDevice 更新名册：最近出现时间写服务端当前时间，快照能力整组替换，位置按
// position 取较大值且不超过当前 head，别名不动。
func (s *Store) TouchDevice(ctx context.Context, userID, deviceID string, snapshotCapable bool, position int64) error {
	head, err := s.currentHead(ctx, userID)
	if err != nil {
		return err
	}
	return s.q.TouchSyncDevice(ctx, db.TouchSyncDeviceParams{
		UserID:          userID,
		DeviceID:        deviceID,
		SnapshotCapable: snapshotCapable,
		SyncedSeq:       position,
		Head:            head,
	})
}

// currentHead 返回账号当前的 head；没有状态行的账号按 0 处理。
func (s *Store) currentHead(ctx context.Context, userID string) (int64, error) {
	row, err := s.q.SyncState(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return row.Head, nil
}

// Devices 按最近出现时间倒序列出名册，最多 limit 条。
func (s *Store) Devices(ctx context.Context, userID string, limit int) ([]syncsvc.Device, error) {
	rows, err := s.q.SyncDevices(ctx, db.SyncDevicesParams{UserID: userID, RowLimit: int32(limit)})
	if err != nil {
		return nil, err
	}
	out := make([]syncsvc.Device, 0, len(rows))
	for _, row := range rows {
		out = append(out, deviceFromRow(row.DeviceID, row.Alias, row.SnapshotCapable, row.SyncedSeq, row.LastSeen.Time))
	}
	return out, nil
}

// RenameDevice 改本账号已有设备的别名，未知设备返回 ErrDeviceNotFound。
func (s *Store) RenameDevice(ctx context.Context, userID, deviceID, alias string) (syncsvc.Device, error) {
	row, err := s.q.RenameSyncDevice(ctx, db.RenameSyncDeviceParams{
		UserID:   userID,
		DeviceID: deviceID,
		Alias:    alias,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return syncsvc.Device{}, syncsvc.ErrDeviceNotFound
	}
	if err != nil {
		return syncsvc.Device{}, err
	}
	return deviceFromRow(row.DeviceID, row.Alias, row.SnapshotCapable, row.SyncedSeq, row.LastSeen.Time), nil
}

// ActiveDeviceWithoutSnapshot 报告最近 since 之后出现过的设备里有没有任何一台
// 不支持快照；名册为空或窗口内没有设备时返回 false。
func (s *Store) ActiveDeviceWithoutSnapshot(ctx context.Context, userID string, since time.Time) (bool, error) {
	at, err := pgTime(since)
	if err != nil {
		return false, err
	}
	return s.q.SyncActiveDeviceWithoutSnapshot(ctx, db.SyncActiveDeviceWithoutSnapshotParams{
		UserID:      userID,
		ActiveSince: at,
	})
}

// ActiveMinSyncedSeq 返回最近 since 之后出现过的设备的最小位置；窗口内没有设备时
// ok 为 false，压缩因此不设上限。
func (s *Store) ActiveMinSyncedSeq(ctx context.Context, userID string, since time.Time) (int64, bool, error) {
	at, err := pgTime(since)
	if err != nil {
		return 0, false, err
	}
	floor, err := s.q.SyncActiveMinSyncedSeq(ctx, db.SyncActiveMinSyncedSeqParams{
		UserID:      userID,
		ActiveSince: at,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return floor, true, nil
}

// deviceFromRow 把库里的一行设备转成 syncsvc 的类型。
func deviceFromRow(deviceID, alias string, snapshotCapable bool, syncedSeq int64, lastSeen time.Time) syncsvc.Device {
	return syncsvc.Device{
		DeviceID:        deviceID,
		Alias:           alias,
		SnapshotCapable: snapshotCapable,
		SyncedSeq:       syncedSeq,
		LastSeen:        lastSeen,
	}
}

// ---- 命名版本（ADR-0054） ----

// Refs 按名字列出全部命名版本，包括墓碑。
func (s *Store) Refs(ctx context.Context, userID string) ([]syncsvc.Ref, error) {
	rows, err := s.q.SyncRefs(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]syncsvc.Ref, 0, len(rows))
	for _, row := range rows {
		out = append(out, syncsvc.Ref{
			Name:      row.Name,
			CommitUID: row.CommitUid,
			Note:      row.Note,
			UpdatedAt: row.UpdatedAt.Time,
			DeletedAt: row.DeletedAt.Time,
		})
	}
	return out, nil
}

// PutRef 写入或删除一个命名版本，返回写入之后存储里的那一行。写入时间不晚于已存
// 删除时间时不复活，返回原来的墓碑；新增一个未删除的名字会超过上限
// （syncsvc.MaxRefsPerAccount）时返回 syncsvc.ErrRefLimit。
func (s *Store) PutRef(ctx context.Context, userID string, ref syncsvc.Ref) (syncsvc.Ref, error) {
	updated, err := pgTime(ref.UpdatedAt)
	if err != nil {
		return syncsvc.Ref{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return syncsvc.Ref{}, err
	}
	defer tx.Rollback(ctx)
	q := s.q.WithTx(tx)
	if _, err := q.LockUser(ctx, userID); err != nil {
		return syncsvc.Ref{}, err
	}
	if ref.DeletedAt.IsZero() {
		sourceTime, err := pgTime(ref.SourceTime())
		if err != nil {
			return syncsvc.Ref{}, err
		}
		row, err := q.PutSyncRefWithinLimit(ctx, db.PutSyncRefWithinLimitParams{
			UserID:          userID,
			Name:            ref.Name,
			CommitUid:       ref.CommitUID,
			Note:            ref.Note,
			UpdatedAt:       updated,
			SourceUpdatedAt: sourceTime,
			MaxAlive:        syncsvc.MaxRefsPerAccount,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			// 0 行有两种原因：名字已经是墓碑且这次写入不晚于删除时间（不复活），或者
			// 未删除的名字已经到上限。前者这一行存在，后者不存在。
			state, err := q.SyncRef(ctx, db.SyncRefParams{UserID: userID, Name: ref.Name})
			if errors.Is(err, pgx.ErrNoRows) {
				return syncsvc.Ref{}, syncsvc.ErrRefLimit
			}
			if err != nil {
				return syncsvc.Ref{}, err
			}
			if state.DeletedAt.Valid && !ref.SourceTime().After(state.DeletedAt.Time) {
				return refFromRow(state.Name, state.CommitUid, state.Note, state.UpdatedAt.Time, state.DeletedAt), nil
			}
			return syncsvc.Ref{}, syncsvc.ErrRefLimit
		}
		if err != nil {
			return syncsvc.Ref{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return syncsvc.Ref{}, err
		}
		return refFromRow(row.Name, row.CommitUid, row.Note, row.UpdatedAt.Time, row.DeletedAt), nil
	}
	row, err := q.DeleteSyncRef(ctx, db.DeleteSyncRefParams{
		UserID:    userID,
		Name:      ref.Name,
		CommitUid: ref.CommitUID,
		Note:      ref.Note,
		UpdatedAt: updated,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// 名字已经是墓碑：这次删除不改动它，读回原来的墓碑。
		state, err := q.SyncRef(ctx, db.SyncRefParams{UserID: userID, Name: ref.Name})
		if err != nil {
			return syncsvc.Ref{}, err
		}
		return refFromRow(state.Name, state.CommitUid, state.Note, state.UpdatedAt.Time, state.DeletedAt), nil
	}
	if err != nil {
		return syncsvc.Ref{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return syncsvc.Ref{}, err
	}
	return refFromRow(row.Name, row.CommitUid, row.Note, row.UpdatedAt.Time, row.DeletedAt), nil
}

// refFromRow 把库里的一行命名版本转成 syncsvc 的类型；deleted_at 为空表示名字仍然
// 有效。
func refFromRow(name, commitUID, note string, updatedAt time.Time, deletedAt pgtype.Timestamptz) syncsvc.Ref {
	ref := syncsvc.Ref{
		Name:      name,
		CommitUID: commitUID,
		Note:      note,
		UpdatedAt: updatedAt,
	}
	if deletedAt.Valid {
		ref.DeletedAt = deletedAt.Time
	}
	return ref
}

// After 返回 seq 大于 after 的提交，按顺序最多 limit 条。页预算只由服务层按
// 序列化之后的大小裁剪，存储这一层只按条数取行。
func (s *Store) After(ctx context.Context, userID string, after int64, limit int) ([]syncsvc.Commit, error) {
	rows, err := s.q.CommitsAfter(ctx, db.CommitsAfterParams{
		UserID:    userID,
		AfterSeq:  after,
		PageLimit: int32(limit),
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
		var tableDigests *map[string]string
		if len(row.TableDigests) > 0 {
			var value map[string]string
			if err := json.Unmarshal(row.TableDigests, &value); err != nil {
				return nil, err
			}
			tableDigests = &value
		}
		out = append(out, syncsvc.Commit{
			Seq:           &seq,
			Uid:           row.Uid,
			Kind:          api.CommitKind(row.Kind),
			DeviceId:      row.DeviceID,
			SchemaVersion: int(row.SchemaVersion),
			Actor:         api.CommitActor(row.Actor),
			Action:        row.Action,
			CreatedAt:     row.CreatedAt,
			ReceivedAt:    &received,
			Changes:       changes,
			StateDigest:   digest,
			TableDigests:  tableDigests,
		})
	}
	return out, nil
}
