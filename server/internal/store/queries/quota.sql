-- 模型代理额度的实例汇总与结算（internal/store/schema.sql 的 llm_usage）。
--
-- 账号当天的预留行由 backup.sql 的 AddTokens 写入；这里补实例预算需要的整表
-- 汇总，以及结算时按预留与实际用量的差额调整同一个行。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次。

-- 实例当天所有账号的总用量。SUM(bigint) 在 PostgreSQL 里返回 numeric，显式转回
-- bigint，调用方拿到的就是 int64；没有行时是 0。
-- name: InstanceTokens :one
SELECT COALESCE(SUM(tokens), 0)::bigint
FROM llm_usage
WHERE day = sqlc.arg(day)::date;

-- 按“实际用量减预留”的差额调整当天用量：多退少补。预留行一定已经由 Reserve 写
-- 好，这里仍然用 upsert，重复结算或异常顺序都不会写坏数据；插入与更新两个分支都
-- 把结果限在 0 以上，异常参数也不会留下负用量。
-- name: SettleTokens :exec
INSERT INTO llm_usage (user_id, day, kind, tokens)
VALUES (
  sqlc.arg(user_id),
  sqlc.arg(day)::date,
  sqlc.arg(kind),
  GREATEST(sqlc.arg(delta)::bigint, 0)
)
ON CONFLICT (user_id, day, kind)
DO UPDATE SET tokens = GREATEST(llm_usage.tokens + sqlc.arg(delta)::bigint, 0);
