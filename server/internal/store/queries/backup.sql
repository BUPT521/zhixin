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

-- 账号当天的共享额度用量，额度判定看已结算量与在途预留之和：同时发起的请求
-- 必须互相看得见，否则各自按旧值通过（ADR-0063、ADR-0071）。
-- name: UsedTokens :one
SELECT COALESCE(SUM(CASE WHEN kind = 'embedding'
  THEN embedding_billed_tokens + embedding_reserved_tokens ELSE tokens + reserved_tokens END), 0)::bigint
FROM llm_usage
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date;

-- 账号当天已经结算的计费 token 数，核销只按这一份算：在途预留还没有产生实际用量，
-- 算进去会在并发时多扣积分（ADR-0071）。
-- name: SettledTokens :one
SELECT COALESCE(SUM(CASE WHEN kind = 'embedding' THEN embedding_billed_tokens ELSE tokens END), 0)::bigint
FROM llm_usage
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date
  AND (sqlc.arg(kind)::text = '' OR kind = sqlc.arg(kind));

-- 记一笔在途预留。api_key_id 记录这次调用用的是哪把密钥，用访问令牌时为空字符串；
-- 结算时由 SettleTokens 把它转进 tokens。
-- name: AddReservedTokens :exec
INSERT INTO llm_usage (user_id, day, kind, api_key_id, reserved_tokens, embedding_reserved_tokens)
VALUES (
  sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(kind),
  sqlc.arg(api_key_id),
  CASE WHEN sqlc.arg(kind)::text = 'chat' THEN sqlc.arg(reserved_tokens)::bigint ELSE 0 END,
  CASE WHEN sqlc.arg(kind) = 'embedding' THEN sqlc.arg(reserved_tokens) ELSE 0 END
)
ON CONFLICT (user_id, day, kind, api_key_id)
DO UPDATE SET
  reserved_tokens = llm_usage.reserved_tokens + EXCLUDED.reserved_tokens,
  embedding_reserved_tokens = llm_usage.embedding_reserved_tokens + EXCLUDED.embedding_reserved_tokens;

-- 按账号调整的每日额度；没有行或者对应列为空时用配置的默认值。
-- name: LLMQuotaOverride :one
SELECT daily_tokens
FROM llm_quota
WHERE user_id = sqlc.arg(user_id);

-- 管理后台读取一个账号的覆盖行：与 LLMQuotaOverride 相比多出备注与保存时间。
-- 没有行时调用方按“没有覆盖”处理，回落到实例默认额度。
-- name: AccountQuota :one
SELECT daily_tokens, note, updated_at
FROM llm_quota
WHERE user_id = sqlc.arg(user_id);

-- 管理后台整体替换一个账号的覆盖值；两项额度都为空时调用方先删除这一行，不写
-- 一条没有意义的记录。updated_at 在更新分支同样推进，页面据此看出最近一次保存。
-- name: UpsertAccountQuota :exec
INSERT INTO llm_quota (user_id, daily_tokens, note, updated_at)
VALUES (
  sqlc.arg(user_id), sqlc.narg(daily_tokens),
  sqlc.arg(note), now()
)
ON CONFLICT (user_id) DO UPDATE SET
  daily_tokens = EXCLUDED.daily_tokens,
  note = EXCLUDED.note,
  updated_at = now();

-- name: DeleteAccountQuota :exec
DELETE FROM llm_quota
WHERE user_id = sqlc.arg(user_id);

-- 管理后台的账号列表一次读回一页账号的覆盖行，避免逐账号查询。
-- name: AccountQuotasByUsers :many
SELECT user_id, daily_tokens, note, updated_at
FROM llm_quota
WHERE user_id = ANY(sqlc.arg(user_ids)::text[]);
