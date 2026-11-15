-- 每个账号的线性提交序列（internal/store/schema.sql 的 sync_head 与 sync_commit）。
--
-- 推送时先锁住 sync_head 再核对 base_seq，整个过程在一个事务里完成（ADR-0015）。

-- name: EnsureSyncHead :exec
INSERT INTO sync_head (user_id, head)
VALUES ($1, 0)
ON CONFLICT (user_id) DO NOTHING;

-- name: LockSyncHead :one
SELECT head
FROM sync_head
WHERE user_id = $1
FOR UPDATE;

-- name: SyncHead :one
SELECT head
FROM sync_head
WHERE user_id = $1;

-- name: ExistingRequestIDs :many
SELECT request_id
FROM sync_commit
WHERE user_id = sqlc.arg(user_id)
  AND request_id = ANY(sqlc.arg(request_ids)::text[]);

-- name: InsertSyncCommit :exec
INSERT INTO sync_commit (
  user_id, seq, request_id, device_id, schema_version,
  actor, action, created_at, changes
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: SetSyncHead :exec
UPDATE sync_head
SET head = $2
WHERE user_id = $1;

-- name: CommitsAfter :many
SELECT seq, request_id, device_id, schema_version, actor, action,
  created_at, received_at, changes
FROM sync_commit
WHERE user_id = $1 AND seq > $2
ORDER BY seq
LIMIT $3;
