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

-- 余额副本（ADR-0069）。查询余额与核销结果覆盖同一个值，负数按 0 落库。
-- name: SaveBalance :exec
INSERT INTO nowpay_balance (user_id, remaining_points, synced_at)
VALUES (sqlc.arg(user_id), GREATEST(sqlc.arg(remaining_points)::bigint, 0), now())
ON CONFLICT (user_id) DO UPDATE
SET remaining_points = GREATEST(sqlc.arg(remaining_points)::bigint, 0),
    synced_at = now();

-- 预留要用的余额副本；没有行表示这个账号还没有同步过余额。
-- name: BalanceForReserve :one
SELECT remaining_points, synced_at FROM nowpay_balance WHERE user_id = sqlc.arg(user_id);

-- 副本同步之后才写入的核销流水合计的积分。副本已经反映它们之前的扣减，这部分
-- 还没有反映；failed 表示确认没有扣减，不计入。
-- name: UnreflectedChargePoints :one
SELECT COALESCE(SUM(points), 0)::bigint FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id)
  AND status <> 'failed'
  AND created_at >= sqlc.arg(synced_at);

-- 当天已经折算成积分的累计计费量：流水里的 billed_tokens 是当时的当天累计量，
-- 取最大值就是最后一次申请时的累计量。failed 的流水没有扣减，不计入。
-- name: ChargedTokens :one
SELECT COALESCE(MAX(billed_tokens), 0)::bigint FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date AND status <> 'failed';
