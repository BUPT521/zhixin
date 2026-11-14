-- name: LockBackupAccount :one
SELECT id FROM app_user WHERE id = $1 FOR UPDATE;

-- name: InsertBackup :exec
INSERT INTO backup (id, user_id, sha256, size, schema_version, device_name, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7);

-- name: Backups :many
SELECT * FROM backup WHERE user_id = $1 ORDER BY created_at DESC, id DESC;

-- name: BackupByID :one
SELECT * FROM backup WHERE user_id = $1 AND id = $2;

-- name: DeleteBackup :execrows
DELETE FROM backup WHERE user_id = $1 AND id = $2;

-- name: PruneBackups :many
DELETE FROM backup
WHERE backup.user_id = $1 AND backup.id IN (
  SELECT b.id FROM backup b WHERE b.user_id = $1 ORDER BY b.created_at DESC, b.id DESC OFFSET sqlc.arg(keep)
)
RETURNING backup.id;

-- name: DeleteUserBackups :many
DELETE FROM backup WHERE user_id = $1 RETURNING id;
