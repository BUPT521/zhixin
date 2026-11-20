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

-- name: InsertSyncCommit :exec
INSERT INTO sync_commit (
  user_id, seq, request_id, device_id, schema_version,
  actor, action, created_at, changes
)
VALUES (
  sqlc.arg(user_id), sqlc.arg(seq), sqlc.arg(request_id),
  sqlc.arg(device_id), sqlc.arg(schema_version), sqlc.arg(actor),
  sqlc.arg(action), sqlc.arg(created_at), sqlc.arg(changes)
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
  c.created_at, c.received_at, c.changes
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
