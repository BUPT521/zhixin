-- 模型代理额度的实例日账本与结算（internal/store/schema.sql 的 llm_usage 与
-- llm_instance_usage）。
--
-- 账号当天的预留行由 backup.sql 的 AddTokens 写入；这里补实例预算需要的账本，
-- 以及结算时按预留与实际用量的差额调整同一个行。实例账本独立于账号，删号不会
-- 减少它（ADR-0036）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次。

-- 实例当天已经占用的 token 数。账本行不存在时返回 0，调用方不必区分“没有行”
-- 与“用量为零”。
-- name: InstanceTokens :one
SELECT COALESCE(
  (SELECT tokens FROM llm_instance_usage WHERE day = sqlc.arg(day)::date),
  0
)::bigint;

-- 按差额调整实例当天的账本：预留时记正数，结算时记多退少补。插入与更新两个分支
-- 都把结果限在 0 以上，异常参数也不会留下负用量。
-- name: AddInstanceTokens :exec
INSERT INTO llm_instance_usage (day, tokens)
VALUES (sqlc.arg(day)::date, GREATEST(sqlc.arg(delta)::bigint, 0))
ON CONFLICT (day)
DO UPDATE SET tokens = GREATEST(llm_instance_usage.tokens + sqlc.arg(delta)::bigint, 0);

-- 按“实际用量减预留”的差额调整当天账号用量：多退少补。预留行一定已经由 Reserve
-- 写好，这里仍然用 upsert，重复结算或异常顺序都不会写坏数据；插入与更新两个分支都
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
