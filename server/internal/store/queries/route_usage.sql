-- name: AddRouteUsage :exec
INSERT INTO llm_route_usage (day, kind, model, provider_id, upstream_model, attempts, successes, tokens, estimated_tokens)
VALUES (
  sqlc.arg(day), sqlc.arg(kind), sqlc.arg(model), sqlc.arg(provider_id), sqlc.arg(upstream_model),
  sqlc.arg(attempts), sqlc.arg(successes), sqlc.arg(tokens), sqlc.arg(estimated_tokens)
)
ON CONFLICT (day, kind, model, provider_id, upstream_model) DO UPDATE SET
  attempts = llm_route_usage.attempts + EXCLUDED.attempts,
  successes = llm_route_usage.successes + EXCLUDED.successes,
  tokens = llm_route_usage.tokens + EXCLUDED.tokens,
  estimated_tokens = llm_route_usage.estimated_tokens + EXCLUDED.estimated_tokens;

-- name: ListRouteUsage :many
SELECT day, kind, model, provider_id, upstream_model, attempts, successes, tokens, estimated_tokens
FROM llm_route_usage
WHERE day BETWEEN sqlc.arg(from_day) AND sqlc.arg(to_day);
