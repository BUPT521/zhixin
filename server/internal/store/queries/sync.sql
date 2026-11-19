-- 每个账号的线性提交序列（internal/store/schema.sql 的 sync_head 与 sync_commit）。
--
-- 推送时先锁住 sync_head 再核对 base_seq，整个过程在一个事务里完成（ADR-0015）。
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次。

-- name: EnsureSyncHead :exec
INSERT INTO sync_head (user_id, head)
VALUES (sqlc.arg(user_id), 0)
ON CONFLICT (user_id) DO NOTHING;

-- name: LockSyncHead :one
SELECT head
FROM sync_head
WHERE user_id = sqlc.arg(user_id)
FOR UPDATE;

-- name: SyncHead :one
SELECT head
FROM sync_head
WHERE user_id = sqlc.arg(user_id);

-- name: SyncIncomingBytes :one
SELECT coalesce(sum(pg_column_size(contents.data)), 0)::bigint
FROM unnest(sqlc.arg(changes)::jsonb[]) AS contents(data);

-- name: ExistingRequestIDs :many
SELECT request_id
FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND request_id = ANY(sqlc.arg(request_ids)::text[]);

-- 清空一个账号的提交序列；sync_head 由调用方在同一事务里 EnsureSyncHead、
-- LockSyncHead 之后用 SetSyncHead 重置为 0，与追加提交共用同一把锁。
-- name: DeleteSyncCommits :exec
DELETE FROM sync_commit
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
