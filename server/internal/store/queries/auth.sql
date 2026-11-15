-- 账号与会话（internal/store/schema.sql 的 app_user 与 session）。
--
-- 参数一律用 sqlc.arg(名字)：生成的方法按名字取参数，改一处绑定不会让另一个
-- 位置的 $n 顺序悄悄错位。

-- name: CreateUser :exec
INSERT INTO app_user (id, email, password_hash)
VALUES (sqlc.arg(id), sqlc.arg(email), sqlc.arg(password_hash));

-- name: UserByEmail :one
SELECT id, email, password_hash, created_at
FROM app_user
WHERE email = sqlc.arg(email);

-- name: UserByID :one
SELECT id, email, password_hash, created_at
FROM app_user
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

-- 删账号不单独删会话：schema.sql 的 session.user_id 上是 ON DELETE CASCADE，
-- 删掉 app_user 那一行时一起消失，所以这里没有 DeleteUserSessions。
