-- 整库备份与模型代理用量（internal/store/schema.sql 的 backup 与 llm_usage）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次，改一处绑定
-- 不会让另一个位置的 $n 顺序悄悄错位。

-- name: InsertBackup :exec
INSERT INTO backup (
  id, user_id, sha256, size, schema_version, device_name, created_at
)
VALUES (
  sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(sha256), sqlc.arg(size),
  sqlc.arg(schema_version), sqlc.arg(device_name), sqlc.arg(created_at)
);

-- name: ListBackups :many
SELECT id, sha256, size, schema_version, device_name, created_at
FROM backup
WHERE user_id = sqlc.arg(user_id)
ORDER BY created_at DESC, id DESC;

-- name: BackupByID :one
SELECT id, sha256, size, schema_version, device_name, created_at
FROM backup
WHERE user_id = sqlc.arg(user_id) AND id = sqlc.arg(id);

-- 按 (user_id, id) 删一行并返回影响行数：存储层只有删到一行才删除对象键，
-- 0 行表示这不是当前账号的备份，绝不能拿 id 去拼键删别人的字节。
-- name: DeleteBackup :execrows
DELETE FROM backup
WHERE user_id = sqlc.arg(user_id) AND id = sqlc.arg(id);

-- 清空一个账号的全部备份。字节由调用方先按 ListBackups 的结果逐个删除对象键，
-- 再调用这一句删元数据行。
-- name: DeleteBackups :exec
DELETE FROM backup
WHERE user_id = sqlc.arg(user_id);


-- 只保留最新的若干份；返回被删掉的那些 id，调用方据此删除对象存储里的字节。
-- name: TrimBackups :many
WITH stale AS (
  SELECT id FROM backup
  WHERE user_id = sqlc.arg(user_id)
  ORDER BY created_at DESC, id DESC
  OFFSET sqlc.arg(keep)
)
DELETE FROM backup
WHERE backup.user_id = sqlc.arg(user_id) AND backup.id IN (SELECT id FROM stale)
RETURNING id;

-- 全部备份的 (账号, id)，供对象存储对账：备份对象在库里找不到对应的行时是遗留
-- 字节，见 ADR-0037。
-- name: ListAllBackups :many
SELECT user_id, id FROM backup;

-- 账号当天的用量按用途汇总，额度判定看已结算量与在途预留之和：同时发起的请求
-- 必须互相看得见，否则各自按旧值通过（ADR-0063、ADR-0071）。
-- name: UsedTokens :one
SELECT COALESCE(SUM(tokens + reserved_tokens), 0)::bigint
FROM llm_usage
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date AND kind = sqlc.arg(kind);

-- 账号当天已经结算的计费 token 数，核销只按这一份算：在途预留还没有产生实际用量，
-- 算进去会在并发时多扣积分（ADR-0071）。
-- name: SettledTokens :one
SELECT COALESCE(SUM(tokens), 0)::bigint
FROM llm_usage
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date AND kind = sqlc.arg(kind);

-- 记一笔在途预留。api_key_id 记录这次调用用的是哪把密钥，用访问令牌时为空字符串；
-- 结算时由 SettleTokens 把它转进 tokens。
-- name: AddReservedTokens :exec
INSERT INTO llm_usage (user_id, day, kind, api_key_id, reserved_tokens)
VALUES (
  sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(kind),
  sqlc.arg(api_key_id), sqlc.arg(reserved_tokens)
)
ON CONFLICT (user_id, day, kind, api_key_id)
DO UPDATE SET reserved_tokens = llm_usage.reserved_tokens + EXCLUDED.reserved_tokens;

-- 按账号调整的每日额度；没有行或者对应列为空时用配置的默认值。
-- name: LLMQuotaOverride :one
SELECT daily_tokens, embedding_daily_tokens
FROM llm_quota
WHERE user_id = sqlc.arg(user_id);
