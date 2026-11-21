-- 每个账号的线性提交序列（internal/store/schema.sql 的 sync_head、sync_commit、
-- sync_snapshot 与 sync_commit_seen）。
--
-- 推送时先锁住 sync_head 再核对 base_seq，整个过程在一个事务里完成（ADR-0015）。
-- 压缩删掉快照覆盖的旧提交时推进 trimmed_through，已经接收过的提交身份另外记在
-- sync_commit_seen 里，因此删除提交不会让重放被重新接收（ADR-0043）。
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次。

-- name: EnsureSyncHead :exec
INSERT INTO sync_head (user_id, head)
VALUES (sqlc.arg(user_id), 0)
ON CONFLICT (user_id) DO NOTHING;

-- name: LockSyncHead :one
SELECT head, trimmed_through
FROM sync_head
WHERE user_id = sqlc.arg(user_id)
FOR UPDATE;

-- name: SyncHead :one
SELECT head, trimmed_through
FROM sync_head
WHERE user_id = sqlc.arg(user_id);

-- name: SyncIncomingBytes :one
SELECT coalesce(sum(pg_column_size(contents.data)), 0)::bigint
FROM unnest(sqlc.arg(changes)::jsonb[]) AS contents(data);

-- 去重同时查提交表与去重表：压缩删除旧提交之后只剩后者，升级前的旧提交只有
-- 前者，两边合起来覆盖全部接收过的身份。
-- name: ExistingRequestIDs :many
SELECT ids.request_id::text
FROM unnest(sqlc.arg(request_ids)::text[]) AS ids(request_id)
WHERE EXISTS (
    SELECT 1 FROM sync_commit c
    WHERE c.user_id = sqlc.arg(user_id) AND c.request_id = ids.request_id
  )
  OR EXISTS (
    SELECT 1 FROM sync_commit_seen s
    WHERE s.user_id = sqlc.arg(user_id) AND s.request_id = ids.request_id
  );

-- name: InsertSyncCommitSeen :exec
INSERT INTO sync_commit_seen (user_id, request_id)
VALUES (sqlc.arg(user_id), sqlc.arg(request_id))
ON CONFLICT DO NOTHING;

-- 清空一个账号的提交序列；sync_head 由调用方在同一事务里 EnsureSyncHead、
-- LockSyncHead 之后用 ResetSyncHead 重置为 0，与追加提交共用同一把锁。
-- name: DeleteSyncCommits :exec
DELETE FROM sync_commit
WHERE user_id = sqlc.arg(user_id);

-- name: DeleteSyncCommitSeen :exec
DELETE FROM sync_commit_seen
WHERE user_id = sqlc.arg(user_id);

-- name: DeleteSyncSnapshot :exec
DELETE FROM sync_snapshot
WHERE user_id = sqlc.arg(user_id);

-- state_digest 是可选的整库摘要：客户端只在推送完成且本机没有待推送提交时带上，
-- 服务端原样保存、不解析，拉取时原样带回（改进方案 3.5）。
-- name: InsertSyncCommit :exec
INSERT INTO sync_commit (
  user_id, seq, request_id, device_id, schema_version,
  actor, action, created_at, changes, state_digest
)
VALUES (
  sqlc.arg(user_id), sqlc.arg(seq), sqlc.arg(request_id),
  sqlc.arg(device_id), sqlc.arg(schema_version), sqlc.arg(actor),
  sqlc.arg(action), sqlc.arg(created_at), sqlc.arg(changes),
  sqlc.narg(state_digest)
);

-- name: SetSyncHead :exec
UPDATE sync_head
SET head = sqlc.arg(head)
WHERE user_id = sqlc.arg(user_id);

-- name: SetSyncTrimmedThrough :exec
UPDATE sync_head
SET trimmed_through = sqlc.arg(trimmed_through)
WHERE user_id = sqlc.arg(user_id);

-- name: ResetSyncHead :exec
UPDATE sync_head
SET head = 0, trimmed_through = 0
WHERE user_id = sqlc.arg(user_id);

-- name: CommitsAfter :many
WITH page AS MATERIALIZED (
  SELECT p.seq AS page_seq, octet_length(p.changes::text)::bigint + octet_length(p.action)
    + octet_length(p.request_id) + octet_length(p.device_id) + 256 AS bytes
  FROM sync_commit p
  WHERE p.user_id = sqlc.arg(user_id) AND p.seq > sqlc.arg(after_seq)
  ORDER BY p.seq
  LIMIT sqlc.arg(page_limit)
), budget AS (
  SELECT page_seq, sum(bytes) OVER (ORDER BY page_seq) AS total FROM page
)
SELECT c.seq, c.request_id, c.device_id, c.schema_version, c.actor, c.action,
  c.created_at, c.received_at, c.changes, c.state_digest
FROM sync_commit c
WHERE c.user_id = sqlc.arg(user_id) AND c.seq IN (
  SELECT budget.page_seq FROM budget
  WHERE budget.total <= sqlc.arg(max_bytes)::bigint
)
ORDER BY c.seq;

-- name: SyncStorageBytes :one
SELECT coalesce(sum(pg_column_size(changes)::bigint + octet_length(action)
  + octet_length(request_id) + octet_length(device_id) + 256), 0)::bigint
FROM sync_commit
WHERE user_id = sqlc.arg(user_id);

-- 常规压缩的删除点：快照位置及之前、服务端收到时间早于保留期的提交里最大的
-- 序号；没有可删的提交时返回 0，调用方据此不动保留下界。
-- name: SyncCompactionPoint :one
SELECT coalesce(max(seq), 0)::bigint
FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND seq <= sqlc.arg(through_seq)
  AND received_at < sqlc.arg(cutoff);

-- 预算压力下的压缩点：不按保留期过滤，快照位置及之前的提交全部可删。
-- name: SyncCompactionLimit :one
SELECT coalesce(max(seq), 0)::bigint
FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND seq <= sqlc.arg(through_seq);

-- name: DeleteSyncCommitsThrough :exec
DELETE FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND seq <= sqlc.arg(through_seq);

-- name: SyncSnapshot :one
SELECT seq, sha256, digest, created_at
FROM sync_snapshot
WHERE user_id = sqlc.arg(user_id);

-- name: UpsertSyncSnapshot :exec
INSERT INTO sync_snapshot (user_id, seq, sha256, digest, created_at)
VALUES (sqlc.arg(user_id), sqlc.arg(seq), sqlc.arg(sha256), sqlc.arg(digest), sqlc.arg(created_at))
ON CONFLICT (user_id) DO UPDATE
SET seq = EXCLUDED.seq,
    sha256 = EXCLUDED.sha256,
    digest = EXCLUDED.digest,
    created_at = EXCLUDED.created_at;

-- ---- 旧快照附件待回收（ADR-0047） ----

-- 登记新指针时记下让位的旧哈希。同一哈希重复出现时保留最早的 orphaned_at，
-- 宽限期因此从第一次让位算起。
-- name: InsertSyncSnapshotOrphan :exec
INSERT INTO sync_snapshot_orphan (user_id, sha256)
VALUES (sqlc.arg(user_id), sqlc.arg(sha256))
ON CONFLICT (user_id, sha256) DO NOTHING;

-- 新指针重新使用一个待回收的哈希时删掉那一行，避免回收一份重新投入使用的附件。
-- name: DeleteSyncSnapshotOrphan :exec
DELETE FROM sync_snapshot_orphan
WHERE user_id = sqlc.arg(user_id) AND sha256 = sqlc.arg(sha256);

-- 清空云端数据时整表清掉。
-- name: DeleteSyncSnapshotOrphans :exec
DELETE FROM sync_snapshot_orphan
WHERE user_id = sqlc.arg(user_id);

-- 可回收的哈希：让位时间早于宽限期，且不是当前快照指针；SQL 这一层也排除，
-- 代码再排除一次，两道都保证当前指针的字节不会被删（ADR-0047）。
-- name: SyncSnapshotOrphansBefore :many
SELECT o.sha256
FROM sync_snapshot_orphan o
WHERE o.user_id = sqlc.arg(user_id)
  AND o.orphaned_at < sqlc.arg(before)
  AND NOT EXISTS (
    SELECT 1 FROM sync_snapshot s
    WHERE s.user_id = o.user_id AND s.sha256 = o.sha256
  )
ORDER BY o.orphaned_at, o.sha256;

-- ---- 设备名册（ADR-0048） ----

-- 带设备标识的同步请求：最近出现时间写服务端当前时间，能力声明整组替换，别名
-- 保持用户设置的值；首次出现时间只在插入时写。
-- name: TouchSyncDevice :exec
INSERT INTO sync_device (user_id, device_id, capabilities)
VALUES (sqlc.arg(user_id), sqlc.arg(device_id), sqlc.arg(capabilities))
ON CONFLICT (user_id, device_id) DO UPDATE
SET capabilities = EXCLUDED.capabilities,
    last_seen = now();

-- 没有设备标识的推送按提交里的设备标识补一行：已有行只更新最近出现时间，能力
-- 与别名都不动，旧版本客户端因此也会出现在名册里。
-- name: EnsureSyncDevice :exec
INSERT INTO sync_device (user_id, device_id)
VALUES (sqlc.arg(user_id), sqlc.arg(device_id))
ON CONFLICT (user_id, device_id) DO UPDATE
SET last_seen = now();

-- name: SyncDevices :many
SELECT device_id, alias, capabilities, first_seen, last_seen
FROM sync_device
WHERE user_id = sqlc.arg(user_id)
ORDER BY last_seen DESC, device_id
LIMIT sqlc.arg(row_limit);

-- 设备改名：只改本账号已有的行，没有这一行时调用方按 404 处理。
-- name: RenameSyncDevice :one
UPDATE sync_device
SET alias = sqlc.arg(alias)
WHERE user_id = sqlc.arg(user_id) AND device_id = sqlc.arg(device_id)
RETURNING device_id, alias, capabilities, first_seen, last_seen;

-- 压缩门槛：最近 active_since 之后出现过的设备里，有没有任何一台的能力声明不含
-- 给定的能力名。名册为空时返回 false，即可以压缩（ADR-0047）。
-- capabilities 为空串或 NULL 时不依赖 string_to_array 的取值语义，直接按“没有
-- 声明任何能力”处理：空能力列表里一定没有 snapshot，旧设备必须挡住压缩。
-- name: SyncActiveDeviceWithoutCapability :one
SELECT EXISTS (
    SELECT 1
    FROM sync_device
    WHERE user_id = sqlc.arg(user_id)
      AND last_seen >= sqlc.arg(active_since)
      AND (
        capabilities IS NULL
        OR capabilities = ''
        OR NOT (sqlc.arg(capability) = ANY (string_to_array(capabilities, ',')))
      )
) AS found;

-- 清空云端数据时整表清掉。
-- name: DeleteSyncDevices :exec
DELETE FROM sync_device
WHERE user_id = sqlc.arg(user_id);
