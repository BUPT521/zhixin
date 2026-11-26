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

-- 管理后台的留存视图从这里读。区间下界由服务层按请求天数与保留期算出；两张表
-- 都是按 day 全表扫描，万行以下不建索引（审查 V4）。
-- name: DailyInstallActive :many
SELECT day, count(*)::bigint AS installs
FROM install_active
WHERE day >= sqlc.arg(since)::date
GROUP BY day
ORDER BY day;

-- name: DailyUserActive :many
SELECT day, count(*)::bigint AS users
FROM user_active
WHERE day >= sqlc.arg(since)::date
GROUP BY day
ORDER BY day;

-- 匿名安装的留存：按第一次出现的日子分组，数一周与四周内再次活跃的安装。首次
-- 当天不算回访（day > first_day），否则每次首次使用都会被算成留存；回访可以落在
-- 下界之后的任意一天，只要还在保留期内。只有首次出现日在下界之内才计入。
-- name: InstallRetentionCohorts :many
WITH first_seen AS (
  SELECT install_hash, min(day)::date AS first_day
  FROM install_active
  GROUP BY install_hash
)
SELECT f.first_day,
       count(*)::bigint AS installs,
       count(*) FILTER (
         WHERE EXISTS (
           SELECT 1 FROM install_active a
           WHERE a.install_hash = f.install_hash
             AND a.day > f.first_day
             AND a.day <= f.first_day + 7
         )
       )::bigint AS returned_7d,
       count(*) FILTER (
         WHERE EXISTS (
           SELECT 1 FROM install_active a
           WHERE a.install_hash = f.install_hash
             AND a.day > f.first_day
             AND a.day <= f.first_day + 28
         )
       )::bigint AS returned_28d
FROM first_seen f
WHERE f.first_day >= sqlc.arg(since)::date
GROUP BY f.first_day
ORDER BY f.first_day;
