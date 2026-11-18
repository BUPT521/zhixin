-- 清除云端数据的标记（internal/store/schema.sql 的 user_purge）。
--
-- 标记的用途有两个：同一个账号同时只允许一次清除；清除期间各写处理器据此
-- 返回 409。超过 10 分钟的标记视为上次中断，新请求用 ClaimPurge 原子接管。

-- name: PurgeStartedAt :one
SELECT started_at
FROM user_purge
WHERE user_id = sqlc.arg(user_id);

-- 原子取得清除权：没有标记时插入；标记早于 stale_before 时覆盖 started_at；
-- 标记还新时条件不成立，影响 0 行，调用方返回 409。并发请求由主键冲突与
-- 行锁排队，只有一个能拿到 1 行。
-- name: ClaimPurge :execrows
INSERT INTO user_purge (user_id, started_at)
VALUES (sqlc.arg(user_id), sqlc.arg(started_at))
ON CONFLICT (user_id) DO UPDATE SET started_at = EXCLUDED.started_at
WHERE user_purge.started_at < sqlc.arg(stale_before);

-- name: EndPurge :exec
DELETE FROM user_purge
WHERE user_id = sqlc.arg(user_id);
