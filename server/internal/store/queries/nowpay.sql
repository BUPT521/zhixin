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

-- name: PurchaseByClientRequestNo :one
SELECT * FROM nowpay_purchase
WHERE user_id = sqlc.arg(user_id) AND client_request_no = sqlc.arg(client_request_no);

-- 账号最近一次可用的购买入口：必须是 ready、带链接且未过期，creating 与 failed 不算。
-- name: LatestPurchaseLink :one
SELECT * FROM nowpay_purchase
WHERE user_id = sqlc.arg(user_id)
  AND state = 'ready'
  AND purchase_url IS NOT NULL
  AND expires_at > sqlc.arg(now)
ORDER BY created_at DESC, out_request_no DESC
LIMIT 1;

-- name: InsertPurchaseLink :exec
INSERT INTO nowpay_purchase
  (out_request_no, client_request_no, user_id, sku_id, state, purchase_url, expires_at)
VALUES
  (sqlc.arg(out_request_no), sqlc.arg(client_request_no), sqlc.arg(user_id), sqlc.arg(sku_id),
   sqlc.narg(state), sqlc.narg(purchase_url), sqlc.arg(expires_at));

-- 同一个幂等键重新生成入口：换成新的 out_request_no，回到 creating 等 purchase.create。
-- name: ReplacePurchaseLink :exec
UPDATE nowpay_purchase
SET out_request_no = sqlc.arg(out_request_no),
    sku_id = sqlc.arg(sku_id),
    state = 'creating',
    purchase_url = NULL,
    expires_at = sqlc.arg(expires_at),
    created_at = now(),
    updated_at = now()
WHERE user_id = sqlc.arg(user_id) AND client_request_no = sqlc.arg(client_request_no);

-- name: ReadyPurchaseLink :exec
UPDATE nowpay_purchase
SET purchase_url = sqlc.arg(purchase_url),
    expires_at = sqlc.arg(expires_at),
    state = 'ready',
    updated_at = now()
WHERE out_request_no = sqlc.arg(out_request_no);

-- name: FailPurchaseLink :exec
UPDATE nowpay_purchase
SET state = 'failed', updated_at = now()
WHERE out_request_no = sqlc.arg(out_request_no);

-- 余额副本（ADR-0069、ADR-0073）。查询余额与核销结果覆盖同一个值，负数按 0 落库；
-- synced_at 是这份余额对应的快照时刻，不是写入时刻。只有不比现有副本旧的快照才覆盖，
-- 查询与核销并发、响应乱序时，晚到的旧快照不会让副本回退。
-- name: SaveBalance :exec
INSERT INTO nowpay_balance (user_id, remaining_points, synced_at)
VALUES (sqlc.arg(user_id), GREATEST(sqlc.arg(remaining_points)::bigint, 0), sqlc.arg(synced_at))
ON CONFLICT (user_id) DO UPDATE
SET remaining_points = GREATEST(sqlc.arg(remaining_points)::bigint, 0),
    synced_at = sqlc.arg(synced_at)
WHERE nowpay_balance.synced_at <= EXCLUDED.synced_at;

-- 预留要用的余额副本；没有行表示这个账号还没有同步过余额。
-- name: BalanceForReserve :one
SELECT remaining_points, synced_at FROM nowpay_balance WHERE user_id = sqlc.arg(user_id);

-- 副本还没有反映的核销积分（ADR-0073）。pending 与 processing 一律计入，因为扣减
-- 还没有确认；succeeded 只有在快照之后才确认的才计入，终态行的 updated_at 视为确认
-- 时间；failed 确认没有扣减，不计入。按确认时间而不是创建时间判断，是因为核销行先
-- 创建、后成功，乱序时旧规则会把已经反映的扣减再算一遍。
-- name: UnreflectedChargePoints :one
SELECT COALESCE(SUM(points), 0)::bigint FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id)
  AND (status IN ('pending', 'processing')
       OR (status = 'succeeded' AND updated_at > sqlc.arg(as_of)));

-- 当天已经折算成积分的累计计费量：流水里的 billed_tokens 是当时的当天累计量，
-- 取最大值就是最后一次申请时的累计量。failed 的流水没有扣减，不计入。
-- name: ChargedTokens :one
SELECT COALESCE(MAX(billed_tokens), 0)::bigint FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date AND status <> 'failed';

-- 当天已经核销成功的积分，账号页用它显示“今天已用积分”。pending 与 processing
-- 还没有确认扣减，failed 确认没有扣减，都不计入。
-- name: ChargedPoints :one
SELECT COALESCE(SUM(points), 0)::bigint FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date AND status = 'succeeded';
