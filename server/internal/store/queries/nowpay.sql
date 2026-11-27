-- 即刻收积分核销与购买入口（ADR-0067）。

-- name: DailyChargeTotals :one
-- 余额表尚未建好时，仍可读取当天已经申请和已经成功的积分。
SELECT COALESCE(SUM(points) FILTER (WHERE status <> 'failed'), 0)::bigint AS applied,
       COALESCE(SUM(points) FILTER (WHERE status = 'succeeded'), 0)::bigint AS charged
FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND day = sqlc.arg(day)::date;

-- name: InsertCharge :exec
INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens)
VALUES (sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(day)::date, sqlc.arg(points), sqlc.arg(billed_tokens));

-- 发送核销之前的本地认领（ADR-0088）：只有 status 仍是 pending、并且 claimed_at
-- 为空或者上一次认领已经超过租约时才成功。状态保持 pending：认领之后进程可能退出，
-- 请求根本没有发出去，processing 只能按请求号查结果，查不到就一直停在那里。
-- name: ClaimCharge :execrows
UPDATE nowpay_charge
SET claimed_at = now()
WHERE id = sqlc.arg(id)
  AND status = 'pending'
  AND (claimed_at IS NULL OR claimed_at < now() - (sqlc.arg(lease_seconds)::int * interval '1 second'));

-- name: UnsettledCharges :many
SELECT * FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id) AND status IN ('pending', 'processing')
ORDER BY created_at, id
LIMIT sqlc.arg(max_rows);

-- 管理后台查看一个账号最近的核销流水，新到旧；删号之后 user_id 被置空的行不取，
-- 它们已经不属于任何账号。只读，不改变流水状态。
-- name: RecentChargesByUser :many
SELECT id, day, points, billed_tokens, status, created_at, updated_at
FROM nowpay_charge
WHERE user_id = sqlc.arg(user_id)
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(max_rows);

-- 全局补查：创建超过宽限期仍未终结的流水，不按账号过滤。核销队列满或进程退出时
-- 留下的流水靠它兜底（ADR-0074 所在的整改方案 P6）。删号之后 user_id 被置空的行
-- 不再取：即刻收的核销与补查都要带买家标识，没有买家标识的行无论补查多少次都只会
-- 失败，留在结果里还会把更晚的流水挤出这一批。这类行由保留期按创建时间删除。
--
-- 按上一次尝试时刻轮转（ADR-0089）：反复失败的流水试过一次就排到后面，积压时更晚
-- 的流水仍然轮得到；从没尝试过的流水排在最前。按创建时间取会让最老的一批永远占住
-- 这一批的名额，后面的流水在 180 天保留期里永远轮不到。
-- name: UnsettledChargesGlobal :many
SELECT * FROM nowpay_charge
WHERE user_id IS NOT NULL AND status IN ('pending', 'processing') AND created_at < sqlc.arg(before)
ORDER BY last_attempt_at ASC NULLS FIRST, created_at, id
LIMIT sqlc.arg(max_rows);

-- 记录一次全局补查的尝试：attempts 加一、last_attempt_at 推到当前时刻，返回落定之
-- 后的状态。加完之后超过上限的流水在这一步落成 abandoned 并写备注，补查拿到这个
-- 状态就不再发送。已经终结的流水不更新，调用方拿不到行、这一份直接丢弃。
--
-- 结果未知的流水不能记 failed：failed 不计入当天已申请量，下一次结算会按差额重新
-- 申请，那一笔可能已经扣过，记 failed 就等于重复扣款（ADR-0089）。
-- name: NoteChargeAttempt :one
UPDATE nowpay_charge
SET attempts = attempts + 1,
    last_attempt_at = now(),
    status = CASE WHEN attempts + 1 > sqlc.arg(max_attempts)::int THEN 'abandoned' ELSE status END,
    note = CASE WHEN attempts + 1 > sqlc.arg(max_attempts)::int
                THEN '补查超过尝试上限，结果未知，不再重试' ELSE note END,
    updated_at = CASE WHEN attempts + 1 > sqlc.arg(max_attempts)::int THEN now() ELSE updated_at END
WHERE id = sqlc.arg(id) AND status IN ('pending', 'processing')
RETURNING status, attempts;

-- 保留期：删号之后 user_id 被置空、又一直没有结论的流水分批删除。它们补查不到
-- 结果，也不会再属于任何账号，只能按创建时间清掉，否则会一直积在 pending 上。
-- name: DeleteOrphanCharges :execrows
DELETE FROM nowpay_charge
WHERE id IN (
  SELECT nowpay_charge.id FROM nowpay_charge
  WHERE nowpay_charge.user_id IS NULL AND nowpay_charge.status IN ('pending', 'processing')
    AND nowpay_charge.created_at < sqlc.arg(before)
  ORDER BY nowpay_charge.created_at
  LIMIT sqlc.arg(max_rows)
);

-- 保留期：过期超过 30 天的购买入口分批删除。
-- name: DeleteExpiredPurchases :execrows
DELETE FROM nowpay_purchase
WHERE out_request_no IN (
  SELECT nowpay_purchase.out_request_no FROM nowpay_purchase
  WHERE nowpay_purchase.expires_at < sqlc.arg(before)
  ORDER BY nowpay_purchase.expires_at
  LIMIT sqlc.arg(max_rows)
);

-- 保留期：终态（succeeded/failed/abandoned）超过 180 天的核销流水分批删除。pending
-- 与 processing 不删，它们还没有结论；abandoned 已经不再重试，按终态一起清理。
-- name: DeleteTerminalCharges :execrows
DELETE FROM nowpay_charge
WHERE id IN (
  SELECT nowpay_charge.id FROM nowpay_charge
  WHERE nowpay_charge.status IN ('succeeded', 'failed', 'abandoned')
    AND nowpay_charge.updated_at < sqlc.arg(before)
  ORDER BY nowpay_charge.updated_at
  LIMIT sqlc.arg(max_rows)
);

-- 按状态统计核销流水，供每日对账日志发现积压。
-- name: ChargeStatusCounts :many
SELECT status, count(*)::bigint AS count FROM nowpay_charge GROUP BY status ORDER BY status;

-- 落核销状态并返回这次的确认时刻。终态行的 updated_at 就是确认时间，核销成功之后
-- 写副本用它做快照的下限，这一笔才不会被算成“快照之后才确认”（ADR-0073）。
-- name: SetChargeStatus :one
UPDATE nowpay_charge
SET status = COALESCE(sqlc.narg(status), status),
    note = sqlc.arg(note),
    updated_at = now()
WHERE id = sqlc.arg(id)
RETURNING updated_at;

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

-- name: PointLedgerWithBalance :one
-- 在同一个查询快照中读余额与流水。余额扣减涵盖所有日期的待确认流水、补查已经放弃
-- 的流水及快照后成功的流水，已申请和已成功的积分只统计指定记账日。abandoned 算进
-- 未反映的核销：它有没有扣过不知道，宁可少放行也不让同一笔积分被花两次（ADR-0089）。
-- synced_at 为空表示从未同步。
SELECT balance.synced_at,
       COALESCE(balance.remaining_points, 0)::bigint AS balance_points,
       COALESCE(SUM(charge.points) FILTER (WHERE charge.day = sqlc.arg(day)::date), 0)::bigint AS applied,
       COALESCE(SUM(charge.points) FILTER (WHERE charge.day = sqlc.arg(day)::date
           AND charge.status = 'succeeded'), 0)::bigint AS charged,
       COALESCE(SUM(charge.points) FILTER (WHERE charge.status IN ('pending', 'processing', 'abandoned')
           OR (charge.status = 'succeeded' AND charge.updated_at > balance.synced_at)), 0)::bigint AS unreflected
FROM (SELECT sqlc.arg(user_id)::text AS user_id) account
LEFT JOIN nowpay_balance AS balance USING (user_id)
LEFT JOIN nowpay_charge AS charge ON charge.user_id = account.user_id AND charge.status <> 'failed'
  AND (charge.day = sqlc.arg(day)::date OR charge.status IN ('pending', 'processing', 'abandoned')
       OR (charge.status = 'succeeded' AND charge.updated_at > balance.synced_at))
GROUP BY balance.synced_at, balance.remaining_points;
