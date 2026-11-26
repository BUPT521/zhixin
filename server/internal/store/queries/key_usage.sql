-- 管理后台按密钥的对账视图（ADR-0076）。
--
-- llm_usage 已经按账号、自然日、用途与签发这次调用的密钥分开记（ADR-0063）：
-- api_key_id 为空字符串的行是访问令牌发起的调用，其余行指向 api_key。这里连同
-- 密钥的名字、前缀、撤销状态与最近使用时间一起读出，管理后台不再自己拼表。
--
-- 密钥撤销超过保留期之后行会被每日清理删除（PruneRevokedKeys），用量行不随它
-- 删除；左连接此时匹配不到，密钥名字退化为空字符串，后台按“已清理的密钥”展示。
-- key_present 记 api_key 行是否还在：不能只看名字与撤销状态，名字为空的密钥与已
-- 清理的密钥都不带名字，撤销状态又只在行还在时才为真。账号删除时 llm_usage 与
-- api_key 都由外键级联删除，不会留下孤儿行。

-- 按天列出区间内每把密钥的已结算与在途用量。行按账号、密钥、自然日与用途分开
-- 返回，聚合交给调用方：后台要按密钥合计，测试要核对单日单用途的数字。
-- name: ListKeyUsage :many
SELECT
  u.day,
  u.user_id,
  u.api_key_id,
  u.kind,
  u.tokens,
  u.reserved_tokens,
  u.input_tokens,
  u.cached_tokens,
  u.attempts,
  u.failures,
  COALESCE(k.name, '')::text AS key_name,
  COALESCE(k.prefix, '')::text AS key_prefix,
  (k.revoked_at IS NOT NULL)::boolean AS revoked,
  (k.id IS NOT NULL)::boolean AS key_present,
  k.last_used_at
FROM llm_usage u
LEFT JOIN api_key k ON k.id = u.api_key_id
WHERE u.day BETWEEN sqlc.arg(from_day)::date AND sqlc.arg(to_day)::date
ORDER BY u.day, u.user_id, u.api_key_id, u.kind;
