-- 附件索引（internal/store/schema.sql 的 attachment）。
--
-- 字节在对象存储里，这里只记“这个账号有这份内容、占多少字节”。账号总量配额按
-- 它求和。参数一律用 sqlc.arg(名字)，与 backup.sql 的约定相同。

-- 幂等写入：同一账号相同内容已经有一行时保持原样，上传用它建立首次的索引行。
-- name: InsertAttachment :execrows
INSERT INTO attachment (user_id, sha256, size)
VALUES (sqlc.arg(user_id), sqlc.arg(sha256), sqlc.arg(size))
ON CONFLICT (user_id, sha256) DO NOTHING;

-- name: AttachmentSize :one
SELECT size
FROM attachment
WHERE user_id = sqlc.arg(user_id) AND sha256 = sqlc.arg(sha256);

-- 账号已用总量：没有行时返回 0，调用方不必区分“空账号”与“没有行”。
-- name: SumAttachmentBytes :one
SELECT COALESCE(SUM(size), 0)::bigint AS used
FROM attachment
WHERE user_id = sqlc.arg(user_id);

-- name: DeleteAttachment :execrows
DELETE FROM attachment
WHERE user_id = sqlc.arg(user_id) AND sha256 = sqlc.arg(sha256);

-- name: DeleteAttachments :exec
DELETE FROM attachment
WHERE user_id = sqlc.arg(user_id);

-- 预留配额前锁住账号行（复用 auth.sql 的 LockUser ... FOR UPDATE）：同一账号的
-- 两次上传因此排队，求和与写入不会同时读到旧的已用量。账号行不存在时返回零行，
-- 存储层按账号不存在处理。

