-- name: LatestPurchase :one
SELECT * FROM model_quota_purchase WHERE user_id = $1 AND sandbox = $2 ORDER BY created_at DESC, id DESC LIMIT 1;

-- name: FindPurchase :one
SELECT * FROM model_quota_purchase WHERE id = $1;

-- name: LockPurchase :one
SELECT * FROM model_quota_purchase WHERE id = $1 FOR UPDATE;

-- name: LockPurchaseOwner :one
SELECT id FROM app_user WHERE id = $1 FOR NO KEY UPDATE;

-- name: InsertPurchase :one
INSERT INTO model_quota_purchase (id, user_id, amount_fen, tokens, app_id, seller_id, sandbox, created_at, expires_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING *;

-- name: SetPurchaseStatus :exec
UPDATE model_quota_purchase
SET status = sqlc.arg(status), trade_id = sqlc.arg(trade_id)
WHERE id = sqlc.arg(id);

-- name: PurchaseBalance :one
SELECT balance_tokens FROM model_quota_wallet WHERE user_id = $1 AND sandbox = $2;

-- name: LockPurchaseBalance :one
SELECT balance_tokens FROM model_quota_wallet WHERE user_id = $1 AND sandbox = $2 FOR UPDATE;

-- name: CreditPurchaseBalance :exec
INSERT INTO model_quota_wallet (user_id, sandbox, balance_tokens) VALUES ($1, $2, $3)
ON CONFLICT (user_id, sandbox) DO UPDATE SET balance_tokens = model_quota_wallet.balance_tokens + EXCLUDED.balance_tokens;

-- name: AdjustPurchaseBalance :exec
UPDATE model_quota_wallet SET balance_tokens = balance_tokens - sqlc.arg(spent)::bigint
WHERE user_id = sqlc.arg(user_id) AND sandbox = sqlc.arg(sandbox);

-- name: PurchasedTokensUsed :one
SELECT COALESCE((
  SELECT tokens FROM model_quota_paid_usage WHERE user_id = sqlc.arg(user_id) AND sandbox = sqlc.arg(sandbox) AND day = sqlc.arg(day)::date
), 0)::bigint;

-- name: AddPurchasedTokensUsed :exec
INSERT INTO model_quota_paid_usage (user_id, sandbox, day, tokens)
VALUES (sqlc.arg(user_id), sqlc.arg(sandbox), sqlc.arg(day)::date, GREATEST(sqlc.arg(spent)::bigint, 0))
ON CONFLICT (user_id, sandbox, day) DO UPDATE SET tokens = model_quota_paid_usage.tokens + sqlc.arg(spent)::bigint;
