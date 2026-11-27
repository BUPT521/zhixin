-- 结算之后还没有申请核销的用量（internal/store/schema.sql 的 llm_charge_pending，
-- ADR-0087）。结算事务里写，补查确认收齐之后删。

-- 记下这一天该收的计费 token。同一天的多笔结算取较大的那个：用量只增不减，后续
-- 结算的累计量覆盖前面的，早来的那一条不会把数改小。
-- name: UpsertPendingCharge :exec
INSERT INTO llm_charge_pending (user_id, day, chargeable_tokens)
VALUES (sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(chargeable_tokens))
ON CONFLICT (user_id, day) DO UPDATE
SET chargeable_tokens = GREATEST(llm_charge_pending.chargeable_tokens, EXCLUDED.chargeable_tokens);

-- 补查：创建早于 before 的待办，不按账号过滤，先到先处理。
-- name: PendingChargesDue :many
SELECT * FROM llm_charge_pending
WHERE created_at < sqlc.arg(before)
ORDER BY created_at, user_id, day
LIMIT sqlc.arg(max_rows);

-- 收齐或超过保留期之后删除待办。
-- name: DeletePendingCharge :exec
DELETE FROM llm_charge_pending
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date;
