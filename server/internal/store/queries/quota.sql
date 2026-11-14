-- name: UsedTokens :one
SELECT tokens FROM llm_usage WHERE user_id = $1 AND day = $2;

-- name: AddTokens :exec
INSERT INTO llm_usage (user_id, day, tokens) VALUES ($1, $2, $3)
ON CONFLICT (user_id, day) DO UPDATE SET tokens = llm_usage.tokens + EXCLUDED.tokens;

-- name: DeleteTokenUsage :exec
DELETE FROM llm_usage WHERE user_id = $1;
