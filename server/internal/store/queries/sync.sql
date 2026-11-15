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
SELECT seq, request_id, device_id, schema_version, actor, action,
  created_at, received_at, changes
FROM sync_commit
WHERE user_id = sqlc.arg(user_id) AND seq > sqlc.arg(after_seq)
ORDER BY seq
LIMIT sqlc.arg(page_limit);
