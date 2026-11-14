-- name: EnsureSyncHead :exec
INSERT INTO sync_head (user_id) VALUES ($1) ON CONFLICT (user_id) DO NOTHING;

-- name: LockSyncHead :one
SELECT head FROM sync_head WHERE user_id = $1 FOR UPDATE;

-- name: SyncHead :one
SELECT head FROM sync_head WHERE user_id = $1;

-- name: SeenSyncRequests :many
SELECT request_id FROM sync_commit
WHERE user_id = $1 AND request_id = ANY(sqlc.arg(request_ids)::text[]);

-- name: InsertSyncCommit :exec
INSERT INTO sync_commit (user_id, seq, request_id, device_id, schema_version, actor, action, created_at, changes)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- name: UpdateSyncHead :exec
UPDATE sync_head SET head = $2 WHERE user_id = $1;

-- name: SyncAfter :many
SELECT * FROM sync_commit WHERE user_id = $1 AND seq > $2 ORDER BY seq LIMIT $3;

-- name: DeleteSyncCommits :exec
DELETE FROM sync_commit WHERE user_id = $1;

-- name: DeleteSyncHead :exec
DELETE FROM sync_head WHERE user_id = $1;
