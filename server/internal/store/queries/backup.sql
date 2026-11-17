-- 整库备份与模型代理用量（internal/store/schema.sql 的 backup 与 llm_usage）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次，改一处绑定
-- 不会让另一个位置的 $n 顺序悄悄错位。

-- name: InsertBackup :exec
INSERT INTO backup (
  id, user_id, sha256, size, schema_version, device_name, created_at
)
VALUES (
  sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(sha256), sqlc.arg(size),
  sqlc.arg(schema_version), sqlc.arg(device_name), sqlc.arg(created_at)
);

-- name: ListBackups :many
SELECT id, sha256, size, schema_version, device_name, created_at
FROM backup
WHERE user_id = sqlc.arg(user_id)
ORDER BY created_at DESC, id DESC;

-- name: BackupByID :one
SELECT id, sha256, size, schema_version, device_name, created_at
FROM backup
WHERE user_id = sqlc.arg(user_id) AND id = sqlc.arg(id);

-- name: DeleteBackup :exec
DELETE FROM backup
WHERE user_id = sqlc.arg(user_id) AND id = sqlc.arg(id);

-- 清空一个账号的全部备份。字节由调用方先按 ListBackups 的结果逐个删除对象键，
-- 再调用这一句删元数据行。
-- name: DeleteBackups :exec
DELETE FROM backup
WHERE user_id = sqlc.arg(user_id);


-- 只保留最新的若干份；返回被删掉的那些 id，调用方据此删除对象存储里的字节。
-- name: TrimBackups :many
WITH stale AS (
  SELECT id FROM backup
  WHERE user_id = sqlc.arg(user_id)
  ORDER BY created_at DESC, id DESC
  OFFSET sqlc.arg(keep)
)
DELETE FROM backup
WHERE backup.user_id = sqlc.arg(user_id) AND backup.id IN (SELECT id FROM stale)
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
