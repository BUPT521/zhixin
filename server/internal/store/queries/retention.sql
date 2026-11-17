-- 留存统计的活跃数据（internal/store/schema.sql 的 user_active 与 install_active）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次，改一处绑定
-- 不会让另一个位置的 $n 顺序悄悄错位。

-- 匿名活跃：同一个安装标识在同一天重复上报只留一行，客户端重试是幂等的。
-- name: MarkInstallActive :exec
INSERT INTO install_active (install_hash, day, app_version, platform)
VALUES (
  sqlc.arg(install_hash), sqlc.arg(day)::date,
  sqlc.arg(app_version), sqlc.arg(platform)
)
ON CONFLICT (install_hash, day) DO NOTHING;

-- 登录账号的活跃：一个账号一天一行。
-- name: MarkUserActive :exec
INSERT INTO user_active (user_id, day)
VALUES (sqlc.arg(user_id), sqlc.arg(day)::date)
ON CONFLICT (user_id, day) DO NOTHING;

-- 按保留期删除匿名活跃。登录账号的活跃数据很小，不随匿名数据一起清理。
-- name: PruneInstallActiveBefore :exec
DELETE FROM install_active
WHERE day < sqlc.arg(before)::date;
