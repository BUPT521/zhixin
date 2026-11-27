-- 结算失败、等待补退的预留（internal/store/schema.sql 的 llm_settlement_failure，
-- ADR-0086）。结算事务失败时记一行，之后在同一个事务里退掉这笔预留并删掉这一行；
-- 没有这份记录，这笔预留会一直占着当天的额度。

-- 记一条结算失败：reserved_tokens 是没能退回的预留，billed_tokens 是这次没有记进
-- 已结算用量的量，只用于日志与人工核对，不参与退预留。
-- name: AddSettlementFailure :exec
INSERT INTO llm_settlement_failure (user_id, day, kind, api_key_id, reserved_tokens, billed_tokens)
VALUES (
  sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(kind), sqlc.arg(api_key_id),
  sqlc.arg(reserved_tokens), sqlc.arg(billed_tokens)
);

-- 一个账号还没有补退的记录。下一次请求先处理它们，再判断额度，用户不会因为上一次
-- 结算失败而继续收到 429。
-- name: SettlementFailuresByUser :many
SELECT * FROM llm_settlement_failure
WHERE user_id = sqlc.arg(user_id)
ORDER BY created_at, id
LIMIT sqlc.arg(max_rows);

-- 全局补查：创建早于 before 的记录，不按账号过滤，兜住不再发起请求的账号与
-- 进程重启之后没人补退的那一批。
-- name: SettlementFailuresDue :many
SELECT * FROM llm_settlement_failure
WHERE created_at < sqlc.arg(before)
ORDER BY created_at, id
LIMIT sqlc.arg(max_rows);

-- 补退成功后删除记录，与退预留处于同一个事务。
-- name: DeleteSettlementFailure :execrows
DELETE FROM llm_settlement_failure WHERE id = sqlc.arg(id);

-- 过去几天的在途预留：一次请求不可能跨两天，这些预留既没有结算也没有补退记录
-- （进程在结算之前退出，或者失败记录也没写进去），清掉之后额度判定不会再被它们
-- 占住。实例账本按自然日各记各的，不跟着改（ADR-0086）。
-- name: ClearReservationsBefore :execrows
UPDATE llm_usage
SET reserved_tokens = 0, embedding_reserved_tokens = 0
WHERE day < sqlc.arg(before)::date
  AND (reserved_tokens <> 0 OR embedding_reserved_tokens <> 0);
