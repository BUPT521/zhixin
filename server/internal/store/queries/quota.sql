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

-- 结算一次预留：把 reserved 从在途预留里扣掉，把 actual 记进已结算用量。行一定
-- 已经由 Reserve 写好，这里仍然用 upsert，重复结算或异常顺序都不会写坏数据；插入
-- 与更新两个分支都把结果限在 0 以上，异常参数也不会留下负用量。行按签发这次调用
-- 的密钥分开记，api_key_id 为空字符串表示访问令牌（ADR-0063）。
--
-- tokens 是已结算的计费 token，reserved_tokens 是在途预留：额度判定看两者之和，
-- 核销只看 tokens（ADR-0071）。input_tokens 与 cached_tokens 是上游报告的原始输入
-- 量与其中命中缓存的部分，只为统计命中率，按差额累加。attempts 与 failures 记录
-- 这一次尝试与它是否失败：失败的尝试按 0 结算，token 两列都不增加，要让后台看得
-- 见失败就只能靠这两个计数（ADR-0083）。
-- name: SettleTokens :exec
INSERT INTO llm_usage (user_id, day, kind, api_key_id, tokens, reserved_tokens, input_tokens, cached_tokens, attempts, failures)
VALUES (
  sqlc.arg(user_id),
  sqlc.arg(day)::date,
  sqlc.arg(kind),
  sqlc.arg(api_key_id),
  GREATEST(sqlc.arg(actual)::bigint, 0),
  0,
  GREATEST(sqlc.arg(input_tokens)::bigint, 0),
  GREATEST(sqlc.arg(cached_tokens)::bigint, 0),
  GREATEST(sqlc.arg(attempts)::bigint, 0),
  GREATEST(sqlc.arg(failures)::bigint, 0)
)
ON CONFLICT (user_id, day, kind, api_key_id)
DO UPDATE SET
  tokens = GREATEST(llm_usage.tokens + sqlc.arg(actual)::bigint, 0),
  reserved_tokens = GREATEST(llm_usage.reserved_tokens - sqlc.arg(reserved)::bigint, 0),
  input_tokens = GREATEST(llm_usage.input_tokens + sqlc.arg(input_tokens)::bigint, 0),
  cached_tokens = GREATEST(llm_usage.cached_tokens + sqlc.arg(cached_tokens)::bigint, 0),
  attempts = GREATEST(llm_usage.attempts + sqlc.arg(attempts)::bigint, 0),
  failures = GREATEST(llm_usage.failures + sqlc.arg(failures)::bigint, 0);

-- 先按用途扣除各自的免费额度，再合计需要由同一积分余额承担的用量。
-- 预留和余额展示计入在途用量，核销只计入已结算用量。
-- name: PointUsage :one
WITH usage_by_kind AS (
  SELECT kind, SUM(tokens + CASE WHEN sqlc.arg(include_reserved)::boolean THEN reserved_tokens ELSE 0 END) AS used
  FROM llm_usage
  WHERE llm_usage.user_id = sqlc.arg(user_id)::text AND llm_usage.day = sqlc.arg(day)::date
  GROUP BY kind
),
usage_with_limits AS (
  SELECT usage.used, CASE usage.kind
    WHEN 'chat' THEN COALESCE(quota.daily_tokens, sqlc.arg(chat_limit)::bigint)
    WHEN 'embedding' THEN COALESCE(quota.embedding_daily_tokens, sqlc.arg(embedding_limit)::bigint)
  END AS free_limit
  FROM usage_by_kind AS usage
  LEFT JOIN llm_quota AS quota ON quota.user_id = sqlc.arg(user_id)::text
)
SELECT COALESCE(SUM(GREATEST(used - free_limit, 0)), 0)::bigint
FROM usage_with_limits
WHERE free_limit > 0;
