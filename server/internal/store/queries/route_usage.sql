-- name: AddRouteUsage :exec
INSERT INTO llm_route_usage (
  day, kind, model, provider_id, upstream_model,
  attempts, first_attempts, failover_attempts, successes, truncated_attempts, canceled_attempts, tokens, estimated_tokens
)
VALUES (
  sqlc.arg(day), sqlc.arg(kind), sqlc.arg(model), sqlc.arg(provider_id), sqlc.arg(upstream_model),
  sqlc.arg(attempts), sqlc.arg(first_attempts), sqlc.arg(failover_attempts), sqlc.arg(successes),
  sqlc.arg(truncated_attempts), sqlc.arg(canceled_attempts), sqlc.arg(tokens), sqlc.arg(estimated_tokens)
)
ON CONFLICT (day, kind, model, provider_id, upstream_model) DO UPDATE SET
  attempts = llm_route_usage.attempts + EXCLUDED.attempts,
  first_attempts = llm_route_usage.first_attempts + EXCLUDED.first_attempts,
  failover_attempts = llm_route_usage.failover_attempts + EXCLUDED.failover_attempts,
  successes = llm_route_usage.successes + EXCLUDED.successes,
  truncated_attempts = llm_route_usage.truncated_attempts + EXCLUDED.truncated_attempts,
  canceled_attempts = llm_route_usage.canceled_attempts + EXCLUDED.canceled_attempts,
  tokens = llm_route_usage.tokens + EXCLUDED.tokens,
  estimated_tokens = llm_route_usage.estimated_tokens + EXCLUDED.estimated_tokens;

-- name: ListRouteUsage :many
SELECT day, kind, model, provider_id, upstream_model,
  attempts, first_attempts, failover_attempts, successes, truncated_attempts, canceled_attempts, tokens, estimated_tokens
FROM llm_route_usage
WHERE day BETWEEN sqlc.arg(from_day) AND sqlc.arg(to_day);
