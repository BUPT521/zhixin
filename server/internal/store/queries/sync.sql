-- 每个账号的同步状态与线性提交序列（internal/store/schema.sql 的 sync_state、
-- sync_commit、sync_commit_seen、sync_device 与 sync_ref）。
--
-- 推送时先锁住 sync_state 这一行再核对 base_seq，整个追加在一个事务里完成
-- （ADR-0015）。压缩删掉快照覆盖的旧提交时推进 trimmed_through，已经接收过的提交
-- 身份另外记在 sync_commit_seen 里（带当时的序号），因此删除提交不会让重放被重新
-- 接收，整批重放也能回出原序号（ADR-0043、ADR-0054）。
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次。

-- ---- 账号同步状态（head、保留下界与快照指针） ----

-- name: EnsureSyncState :exec
INSERT INTO sync_state (user_id, head)
VALUES (sqlc.arg(user_id), 0)
ON CONFLICT (user_id) DO NOTHING;

-- name: LockSyncState :one
SELECT head, trimmed_through, snapshot_seq, snapshot_sha256, snapshot_digest, snapshot_created_at
FROM sync_state
WHERE user_id = sqlc.arg(user_id)
FOR UPDATE;

-- name: SyncState :one
SELECT head, trimmed_through, snapshot_seq, snapshot_sha256, snapshot_digest, snapshot_created_at
FROM sync_state
WHERE user_id = sqlc.arg(user_id);

-- name: SyncIncomingBytes :one
SELECT coalesce(sum(pg_column_size(contents.data)), 0)::bigint
FROM unnest(sqlc.arg(changes)::jsonb[]) AS contents(data);

-- 去重同时查提交表与去重表：压缩删除旧提交之后只剩后者，两边合起来覆盖全部接收过
-- 的身份，并给出重复提交原来分配的序号。
-- name: ExistingCommitSeqs :many
SELECT DISTINCT ON (ids.uid) ids.uid::text, coalesce(c.seq, s.seq)::bigint AS seq
FROM unnest(sqlc.arg(uids)::text[]) AS ids(uid)
LEFT JOIN sync_commit c
  ON c.user_id = sqlc.arg(user_id) AND c.uid = ids.uid
LEFT JOIN sync_commit_seen s
  ON s.user_id = sqlc.arg(user_id) AND s.uid = ids.uid
WHERE c.seq IS NOT NULL OR s.seq IS NOT NULL;

-- 插入去重记录时同时写这次分配的序号，压缩删掉提交之后重复推送仍回得到它。
-- name: InsertSyncCommitSeen :exec
INSERT INTO sync_commit_seen (user_id, uid, seq)
VALUES (sqlc.arg(user_id), sqlc.arg(uid), sqlc.arg(seq))
ON CONFLICT DO NOTHING;

-- 清空一个账号的提交序列；sync_state 由调用方在同一事务里 EnsureSyncState、
-- LockSyncState 之后用 ResetSyncState 重置为 0，与追加提交共用同一把锁。
-- name: DeleteSyncCommits :exec
DELETE FROM sync_commit
WHERE user_id = sqlc.arg(user_id);

-- name: DeleteSyncCommitSeen :exec
DELETE FROM sync_commit_seen
WHERE user_id = sqlc.arg(user_id);

-- state_digest 与 table_digests 都是可选摘要：客户端只在推送完成且本机没有待推送
-- 提交时带上，服务端原样保存、不解析，拉取时原样带回（改进方案 3.5、ADR-0054）。
-- name: InsertSyncCommit :exec
INSERT INTO sync_commit (
  user_id, seq, uid, device_id, schema_version,
  actor, action, created_at, changes, state_digest, table_digests
)
VALUES (
  sqlc.arg(user_id), sqlc.arg(seq), sqlc.arg(uid),
  sqlc.arg(device_id), sqlc.arg(schema_version), sqlc.arg(actor),
  sqlc.arg(action), sqlc.arg(created_at), sqlc.arg(changes),
  sqlc.narg(state_digest), sqlc.narg(table_digests)
);

-- name: SetSyncHead :exec
UPDATE sync_state
SET head = sqlc.arg(head)
WHERE user_id = sqlc.arg(user_id);

-- name: SetSyncTrimmedThrough :exec
UPDATE sync_state
SET trimmed_through = sqlc.arg(trimmed_through)
WHERE user_id = sqlc.arg(user_id);

-- 清空云端数据与删号：head、保留下界与快照指针一起回到初始状态。
-- name: ResetSyncState :exec
UPDATE sync_state
SET head = 0, trimmed_through = 0,
    snapshot_seq = NULL, snapshot_sha256 = NULL, snapshot_digest = NULL,
    snapshot_created_at = NULL
WHERE user_id = sqlc.arg(user_id);

-- 登记用快照指针覆盖整组四个列；没有旧指针时这里就是第一次登记。
-- name: UpsertSyncSnapshot :exec
INSERT INTO sync_state (
  user_id, snapshot_seq, snapshot_sha256, snapshot_digest, snapshot_created_at
)
VALUES (
  sqlc.arg(user_id), sqlc.arg(snapshot_seq), sqlc.arg(snapshot_sha256),
  sqlc.arg(snapshot_digest), sqlc.arg(snapshot_created_at)
)
ON CONFLICT (user_id) DO UPDATE
SET snapshot_seq = EXCLUDED.snapshot_seq,
    snapshot_sha256 = EXCLUDED.snapshot_sha256,
    snapshot_digest = EXCLUDED.snapshot_digest,
    snapshot_created_at = EXCLUDED.snapshot_created_at;

-- name: CommitsAfter :many
WITH page AS MATERIALIZED (
  SELECT p.seq AS page_seq, octet_length(p.changes::text)::bigint + octet_length(p.action)
    + octet_length(p.uid) + octet_length(p.device_id) + 256 AS bytes
  FROM sync_commit p
  WHERE p.user_id = sqlc.arg(user_id) AND p.seq > sqlc.arg(after_seq)
  ORDER BY p.seq
  LIMIT sqlc.arg(page_limit)
), budget AS (
  SELECT page_seq, sum(bytes) OVER (ORDER BY page_seq) AS total FROM page
)
SELECT c.seq, c.uid, c.device_id, c.schema_version, c.actor, c.action,
  c.created_at, c.received_at, c.changes, c.state_digest, c.table_digests
FROM sync_commit c
WHERE c.user_id = sqlc.arg(user_id) AND c.seq IN (
  SELECT budget.page_seq FROM budget
  WHERE budget.total <= sqlc.arg(max_bytes)::bigint
)
ORDER BY c.seq;

-- name: SyncStorageBytes :one
SELECT coalesce(sum(pg_column_size(changes)::bigint + octet_length(action)
  + octet_length(uid) + octet_length(device_id) + 256), 0)::bigint
FROM sync_commit
WHERE user_id = sqlc.arg(user_id);

-- 常规压缩的删除点：快照位置及之前、服务端收到时间早于保留期、且不越过活跃窗口内
-- 设备最小位置（floor_seq）的提交里最大的序号；没有可删的提交时返回 0，调用方据此
-- 不动保留下界（ADR-0043、ADR-0054）。floor_seq 不大于零表示窗口内没有设备，不设
-- 位置上限。
-- name: SyncCompactionPoint :one
SELECT coalesce(max(seq), 0)::bigint
FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND seq <= sqlc.arg(through_seq)
  AND (sqlc.arg(floor_seq)::bigint <= 0 OR seq <= sqlc.arg(floor_seq)::bigint)
  AND received_at < sqlc.arg(cutoff);

-- 预算压力下的压缩点：不按保留期与设备位置过滤，快照位置及之前的提交全部可删。
-- name: SyncCompactionLimit :one
SELECT coalesce(max(seq), 0)::bigint
FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND seq <= sqlc.arg(through_seq);

-- name: DeleteSyncCommitsThrough :exec
DELETE FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND seq <= sqlc.arg(through_seq);

-- ---- 旧快照附件（ADR-0047、审查 V2） ----

-- 旧指针让位时标记旧哈希那一行；这一行已经标记过时保留最早的 orphaned_at，宽限期
-- 因此从第一次让位算起。这一行不存在（字节或索引早就不在）时什么也不做。
-- name: MarkAttachmentOrphaned :exec
UPDATE attachment
SET orphaned_at = now()
WHERE user_id = sqlc.arg(user_id) AND sha256 = sqlc.arg(sha256) AND orphaned_at IS NULL;

-- 新指针重新使用一个待回收的哈希时清掉标记，避免回收一份重新投入使用的附件；
-- 顺利登记时连旧指针的标记也清掉，指针换回来之后两份附件都还在使用。
-- name: ClearAttachmentOrphaned :exec
UPDATE attachment
SET orphaned_at = NULL
WHERE user_id = sqlc.arg(user_id)
  AND (sha256 = ANY (sqlc.arg(current_sha256s)::text[]) OR sha256 = sqlc.arg(sha256));

-- 可回收的哈希：让位时间早于宽限期，且不是当前快照指针；SQL 这一层与代码都排除
-- 当前指针，两道都保证当前指针的字节不会被删。
-- name: AttachmentsOrphanedBefore :many
SELECT a.sha256
FROM attachment a
WHERE a.user_id = sqlc.arg(user_id)
  AND a.orphaned_at IS NOT NULL
  AND a.orphaned_at < sqlc.arg(before)
  AND (sqlc.narg(current_sha256)::text IS NULL OR a.sha256 <> sqlc.narg(current_sha256)::text)
ORDER BY a.orphaned_at, a.sha256;

-- 清空云端数据时清掉本账号全部附件的回收标记；附件索引与字节由附件存储另行清。
-- name: ClearAttachmentsOrphaned :exec
UPDATE attachment
SET orphaned_at = NULL
WHERE user_id = sqlc.arg(user_id);

-- ---- 设备名册（ADR-0048、ADR-0054） ----

-- 带设备标识的同步请求：最近出现时间写服务端当前时间，快照能力整组替换，位置按
-- after 取较大值且不超过当前 head，别名保持用户设置的值；首次出现时间只在插入时写。
-- name: TouchSyncDevice :exec
INSERT INTO sync_device (user_id, device_id, snapshot_capable, synced_seq)
VALUES (
  sqlc.arg(user_id), sqlc.arg(device_id), sqlc.arg(snapshot_capable),
  least(sqlc.arg(synced_seq)::bigint, sqlc.arg(head)::bigint)
)
ON CONFLICT (user_id, device_id) DO UPDATE
SET snapshot_capable = EXCLUDED.snapshot_capable,
    synced_seq = least(greatest(sync_device.synced_seq, EXCLUDED.synced_seq), sqlc.arg(head)::bigint),
    last_seen = now();

-- 没有设备标识的推送按提交里的设备标识补一行：已有行只更新最近出现时间，能力、
-- 位置与别名都不动，旧版本客户端因此也会出现在名册里。
-- name: EnsureSyncDevice :exec
INSERT INTO sync_device (user_id, device_id)
VALUES (sqlc.arg(user_id), sqlc.arg(device_id))
ON CONFLICT (user_id, device_id) DO UPDATE
SET last_seen = now();

-- 推送之后推进设备位置：确有新提交写入时推到新 head，整批重放时只按 base 取较大值，
-- 两种情况都不超过当前 head（ADR-0054）。
-- name: AdvanceSyncDevice :exec
UPDATE sync_device
SET synced_seq = least(
      greatest(synced_seq, sqlc.arg(base_seq)::bigint,
        CASE WHEN sqlc.arg(to_head)::boolean THEN sqlc.arg(head)::bigint ELSE 0::bigint END),
      sqlc.arg(head)::bigint),
    last_seen = now()
WHERE user_id = sqlc.arg(user_id) AND device_id = sqlc.arg(device_id);

-- name: SyncDevices :many
SELECT device_id, alias, snapshot_capable, synced_seq, first_seen, last_seen
FROM sync_device
WHERE user_id = sqlc.arg(user_id)
ORDER BY last_seen DESC, device_id
LIMIT sqlc.arg(row_limit);

-- 设备改名：只改本账号已有的行，没有这一行时调用方按 404 处理。
-- name: RenameSyncDevice :one
UPDATE sync_device
SET alias = sqlc.arg(alias)
WHERE user_id = sqlc.arg(user_id) AND device_id = sqlc.arg(device_id)
RETURNING device_id, alias, snapshot_capable, synced_seq, first_seen, last_seen;

-- 压缩门槛：最近 active_since 之后出现过的设备里，有没有任何一台没有声明 snapshot
-- 能力。名册为空或窗口内没有设备时返回 false，即可以压缩（ADR-0047）。
-- name: SyncActiveDeviceWithoutSnapshot :one
SELECT EXISTS (
    SELECT 1
    FROM sync_device
    WHERE user_id = sqlc.arg(user_id)
      AND last_seen >= sqlc.arg(active_since)
      AND NOT snapshot_capable
) AS found;

-- 常规压缩的设备位置门槛：活跃窗口内设备的最小 synced_seq；窗口内没有设备时返回
-- NULL，调用方据此不设上限（ADR-0054）。
-- name: SyncActiveMinSyncedSeq :one
SELECT min(synced_seq)::bigint AS floor_seq
FROM sync_device
WHERE user_id = sqlc.arg(user_id)
  AND last_seen >= sqlc.arg(active_since)
HAVING min(synced_seq) IS NOT NULL;

-- 清空云端数据时整表清掉。
-- name: DeleteSyncDevices :exec
DELETE FROM sync_device
WHERE user_id = sqlc.arg(user_id);

-- ---- 命名版本（ADR-0054） ----

-- name: SyncRefs :many
SELECT name, commit_uid, note, updated_at, deleted_at
FROM sync_ref
WHERE user_id = sqlc.arg(user_id)
ORDER BY name;

-- 写入一个命名版本。后写覆盖先写；名字已经是墓碑时，只有这次的写入时间晚于删除
-- 时间才复活，更早的写入什么都不改（受影响行数为 0）。
-- name: PutSyncRef :execrows
INSERT INTO sync_ref (user_id, name, commit_uid, note, updated_at, deleted_at)
VALUES (
  sqlc.arg(user_id), sqlc.arg(name), sqlc.arg(commit_uid), sqlc.arg(note),
  sqlc.arg(updated_at), NULL
)
ON CONFLICT (user_id, name) DO UPDATE
SET commit_uid = EXCLUDED.commit_uid,
    note = EXCLUDED.note,
    updated_at = EXCLUDED.updated_at,
    deleted_at = NULL
WHERE sync_ref.deleted_at IS NULL OR sync_ref.deleted_at < EXCLUDED.updated_at;

-- 删除一个名字：已经是墓碑时保留最早的删除时间；写入时间早于删除时间时什么都不
-- 改。函数调用放在标量位置，与 PutSyncRef 的写入时间在同一事务里各取一次。
-- name: DeleteSyncRef :execrows
INSERT INTO sync_ref (user_id, name, commit_uid, note, updated_at, deleted_at)
VALUES (
  sqlc.arg(user_id), sqlc.arg(name), sqlc.arg(commit_uid), sqlc.arg(note),
  statement_timestamp(), statement_timestamp()
)
ON CONFLICT (user_id, name) DO UPDATE
SET deleted_at = LEAST(sync_ref.deleted_at, EXCLUDED.deleted_at)
WHERE sync_ref.deleted_at IS NULL OR sync_ref.deleted_at < EXCLUDED.updated_at;

-- 写入一个命名版本并核对每账号的上限：新名字（原来没有或只在墓碑上）会新增一个
-- 未删除的名字，未删除的条数已经到上限时受影响行数为 0，调用方按 ErrRefLimit
-- 处理。判断与写入在同一句里完成，并发写入不会把条数推过上限。
-- name: PutSyncRefWithinLimit :execrows
INSERT INTO sync_ref (user_id, name, commit_uid, note, updated_at, deleted_at)
SELECT sqlc.arg(user_id), sqlc.arg(name), sqlc.arg(commit_uid), sqlc.arg(note),
  sqlc.arg(updated_at), NULL
WHERE sqlc.arg(max_alive)::bigint > (
  SELECT count(*) FROM sync_ref
  WHERE user_id = sqlc.arg(user_id) AND deleted_at IS NULL
)
ON CONFLICT (user_id, name) DO UPDATE
SET commit_uid = EXCLUDED.commit_uid,
    note = EXCLUDED.note,
    updated_at = EXCLUDED.updated_at,
    deleted_at = NULL
WHERE sync_ref.deleted_at IS NULL OR sync_ref.deleted_at < EXCLUDED.updated_at;

-- 写入之后核对一行：0 行说明这个名字已经不在，或者这次写入没有生效。
-- name: SyncRef :one
SELECT name, commit_uid, note, updated_at, deleted_at
FROM sync_ref
WHERE user_id = sqlc.arg(user_id) AND name = sqlc.arg(name);
-- 清空云端数据时整表清掉，墓碑一并清掉。
-- name: DeleteSyncRefs :exec
DELETE FROM sync_ref
WHERE user_id = sqlc.arg(user_id);
