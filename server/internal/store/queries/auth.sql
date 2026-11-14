-- name: CreateUser :exec
INSERT INTO app_user (id, email, password_hash, created_at) VALUES ($1, $2, $3, $4);

-- name: UserByEmail :one
SELECT * FROM app_user WHERE email = $1;

-- name: UserByID :one
SELECT * FROM app_user WHERE id = $1;

-- name: DeleteAccount :execrows
DELETE FROM app_user WHERE id = $1;

-- name: CreateSession :exec
INSERT INTO session (id, user_id, device_name, access_hash, refresh_hash, access_expires, refresh_expires, created_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8);

-- name: SessionByAccessHash :one
SELECT * FROM session WHERE access_hash = $1;

-- name: SessionByRefreshHash :one
SELECT * FROM session WHERE refresh_hash = $1;

-- name: DeleteSession :execrows
DELETE FROM session WHERE id = $1;

-- name: DeleteUserSessions :exec
DELETE FROM session WHERE user_id = $1;
