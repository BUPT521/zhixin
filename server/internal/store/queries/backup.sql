-- 整库备份与模型代理用量（internal/store/schema.sql 的 backup 与 llm_usage）。

-- name: InsertBackup :exec
INSERT INTO backup (
  id, user_id, sha256, size, schema_version, device_name, created_at
)
VALUES ($1, $2, $3, $4, $5, $6, $7);

-- name: ListBackups :many
SELECT id, sha256, size, schema_version, device_name, created_at
FROM backup
WHERE user_id = $1
ORDER BY created_at DESC, id DESC;

-- name: BackupByID :one
SELECT id, sha256, size, schema_version, device_name, created_at
FROM backup
WHERE user_id = $1 AND id = $2;

-- name: DeleteBackup :exec
DELETE FROM backup
WHERE user_id = $1 AND id = $2;

-- name: DeleteUserBackups :exec
DELETE FROM backup
WHERE user_id = $1;

-- 只保留最新的若干份；返回被删掉的那些 id，调用方据此删除对象存储里的字节。
-- name: TrimBackups :many
WITH stale AS (
  SELECT id FROM backup
  WHERE user_id = $1
  ORDER BY created_at DESC, id DESC
  OFFSET $2
)
DELETE FROM backup
WHERE backup.user_id = $1 AND backup.id IN (SELECT id FROM stale)
RETURNING id;

-- name: UsedTokens :one
SELECT tokens
FROM llm_usage
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date;

-- name: AddTokens :exec
INSERT INTO llm_usage (user_id, day, tokens)
VALUES (sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(tokens))
ON CONFLICT (user_id, day)
DO UPDATE SET tokens = llm_usage.tokens + EXCLUDED.tokens;

-- name: DeleteUserUsage :exec
DELETE FROM llm_usage
WHERE user_id = $1;
