-- 账号与会话（internal/store/schema.sql 的 app_user 与 session）。
--
-- 参数一律用 sqlc.arg(名字)：生成的方法按名字取参数，改一处绑定不会让另一个
-- 位置的 $n 顺序悄悄错位。

-- name: CreateUser :exec
INSERT INTO app_user (id, email, password_hash)
VALUES (sqlc.arg(id), sqlc.arg(email), sqlc.arg(password_hash));

-- name: UserByEmail :one
SELECT id, email, password_hash, email_verified_at, created_at
FROM app_user
WHERE email = sqlc.arg(email);

-- name: UserByID :one
SELECT id, email, password_hash, email_verified_at, created_at
FROM app_user
WHERE id = sqlc.arg(id);

-- name: SetEmailVerified :exec
UPDATE app_user
SET email_verified_at = sqlc.arg(verified_at)
WHERE id = sqlc.arg(id);

-- name: UpdatePassword :exec
UPDATE app_user
SET password_hash = sqlc.arg(password_hash)
WHERE id = sqlc.arg(id);

-- name: DeleteUser :execrows
DELETE FROM app_user
WHERE id = sqlc.arg(id);

-- name: CreateSession :exec
INSERT INTO session (
  id, user_id, device_name, access_hash, refresh_hash,
  access_expires, refresh_expires
)
VALUES (
  sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(device_name),
  sqlc.arg(access_hash), sqlc.arg(refresh_hash),
  sqlc.arg(access_expires), sqlc.arg(refresh_expires)
);

-- 建会话之前锁住账号行：同一账号的并发登录在锁上串行，先删最旧再插入，会话
-- 数不会因为并发而超上限。锁的是一行账号，不同账号互不影响。
-- name: LockUser :one
SELECT id FROM app_user WHERE id = sqlc.arg(id) FOR UPDATE;

-- 只保留最新的 keep 条会话，更旧的删掉。排序带上 id，创建时间相同时结果稳定。
-- name: DeleteOldestSessions :exec
DELETE FROM session AS doomed
WHERE doomed.user_id = sqlc.arg(user_id)
  AND doomed.id NOT IN (
    SELECT kept.id
    FROM session AS kept
    WHERE kept.user_id = sqlc.arg(user_id)
    ORDER BY kept.created_at DESC, kept.id DESC
    LIMIT sqlc.arg(keep)
  );

-- name: PruneExpiredSessions :exec
DELETE FROM session
WHERE refresh_expires < sqlc.arg(now);

-- name: PruneExpiredAuthCodes :exec
DELETE FROM auth_code
WHERE expires_at < sqlc.arg(now);

-- name: SessionByAccessHash :one
SELECT id, user_id, device_name, access_hash, refresh_hash,
  access_expires, refresh_expires, created_at
FROM session
WHERE access_hash = sqlc.arg(access_hash);

-- name: SessionByRefreshHash :one
SELECT id, user_id, device_name, access_hash, refresh_hash,
  access_expires, refresh_expires, created_at
FROM session
WHERE refresh_hash = sqlc.arg(refresh_hash);

-- name: DeleteSession :execrows
DELETE FROM session
WHERE id = sqlc.arg(id);

-- 重设密码之后作废这个账号的全部会话：其他设备必须重新登录。
-- name: DeleteUserSessions :exec
DELETE FROM session
WHERE user_id = sqlc.arg(user_id);

-- 删账号不单独删会话：schema.sql 的 session.user_id 上是 ON DELETE CASCADE，
-- 删掉 app_user 那一行时一起消失。

-- name: PutAuthCode :exec
INSERT INTO auth_code (user_id, purpose, code_hash, expires_at, attempts, created_at)
VALUES (
  sqlc.arg(user_id), sqlc.arg(purpose), sqlc.arg(code_hash),
  sqlc.arg(expires_at), 0, sqlc.arg(created_at)
)
ON CONFLICT (user_id, purpose) DO UPDATE SET
  code_hash = excluded.code_hash,
  expires_at = excluded.expires_at,
  attempts = 0,
  created_at = excluded.created_at;

-- name: AuthCode :one
SELECT user_id, purpose, code_hash, expires_at, attempts, created_at
FROM auth_code
WHERE user_id = sqlc.arg(user_id) AND purpose = sqlc.arg(purpose);

-- name: IncrementAuthCodeAttempts :one
UPDATE auth_code
SET attempts = attempts + 1
WHERE user_id = sqlc.arg(user_id) AND purpose = sqlc.arg(purpose)
RETURNING attempts;

-- name: DeleteAuthCode :exec
DELETE FROM auth_code
WHERE user_id = sqlc.arg(user_id) AND purpose = sqlc.arg(purpose);
