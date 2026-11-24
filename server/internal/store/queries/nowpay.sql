-- 即刻收积分核销与购买入口（ADR-0067）。

-- name: AppliedChargePoints :one
-- 同一个账号同一天已经申请的积分合计；failed 表示确认没有扣减，不计入。
SELECT COALESCE(SUM(points), 0)::bigint FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date AND status <> 'failed';

-- name: InsertCharge :exec
INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens)
VALUES (sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(points), sqlc.arg(billed_tokens));

-- name: UnsettledCharges :many
SELECT * FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND status IN ('pending', 'processing')
ORDER BY created_at, id
LIMIT sqlc.arg(max_rows);

-- name: SetChargeStatus :exec
UPDATE nowpay_charge
SET status = COALESCE(sqlc.narg(status), status),
    note = sqlc.arg(note),
    updated_at = now()
WHERE id = sqlc.arg(id);

-- name: LatestPurchaseLink :one
SELECT * FROM nowpay_purchase
WHERE user_id = sqlc.arg(user_id) AND expires_at > sqlc.arg(now)
ORDER BY created_at DESC, out_request_no DESC
LIMIT 1;

-- name: InsertPurchaseLink :exec
INSERT INTO nowpay_purchase (out_request_no, user_id, sku_id, purchase_url, expires_at)
VALUES (sqlc.arg(out_request_no), sqlc.arg(user_id), sqlc.arg(sku_id), sqlc.arg(purchase_url), sqlc.arg(expires_at));
