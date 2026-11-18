-- 模型来源、对外模型与路由（internal/store/schema.sql 的 llm_provider、
-- llm_model 与 llm_route，ADR-0028）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次，改一处绑定
-- 不会让另一个位置的 $n 顺序悄悄错位。

-- name: ListLLMProviders :many
SELECT id, name, base_url, api_key_sealed, key_hint, enabled, note, updated_at
FROM llm_provider
ORDER BY id;

-- name: GetLLMProvider :one
SELECT id, name, base_url, api_key_sealed, key_hint, enabled, note, updated_at
FROM llm_provider
WHERE id = sqlc.arg(id);

-- name: UpsertLLMProvider :exec
INSERT INTO llm_provider (id, name, base_url, api_key_sealed, key_hint, enabled, note, updated_at)
VALUES (
  sqlc.arg(id), sqlc.arg(name), sqlc.arg(base_url), sqlc.arg(api_key_sealed),
  sqlc.arg(key_hint), sqlc.arg(enabled), sqlc.arg(note), sqlc.arg(updated_at)
)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  base_url = EXCLUDED.base_url,
  api_key_sealed = EXCLUDED.api_key_sealed,
  key_hint = EXCLUDED.key_hint,
  enabled = EXCLUDED.enabled,
  note = EXCLUDED.note,
  updated_at = EXCLUDED.updated_at;

-- name: DeleteLLMProvider :execrows
DELETE FROM llm_provider WHERE id = sqlc.arg(id);

-- name: CountRoutesForProvider :one
SELECT count(*) FROM llm_route WHERE provider_id = sqlc.arg(provider_id);

-- name: ListLLMModels :many
SELECT name, kind, enabled, dimensions, note, updated_at
FROM llm_model
ORDER BY name;

-- name: ListLLMRoutes :many
SELECT model, provider_id, upstream_model, priority, weight, max_batch, enabled
FROM llm_route
ORDER BY model, position;

-- name: UpsertLLMModel :exec
INSERT INTO llm_model (name, kind, enabled, dimensions, note, updated_at)
VALUES (
  sqlc.arg(name), sqlc.arg(kind), sqlc.arg(enabled), sqlc.narg(dimensions),
  sqlc.arg(note), sqlc.arg(updated_at)
)
ON CONFLICT (name) DO UPDATE SET
  kind = EXCLUDED.kind,
  enabled = EXCLUDED.enabled,
  dimensions = EXCLUDED.dimensions,
  note = EXCLUDED.note,
  updated_at = EXCLUDED.updated_at;

-- name: DeleteLLMRoutesForModel :exec
DELETE FROM llm_route WHERE model = sqlc.arg(model);

-- name: InsertLLMRoute :exec
INSERT INTO llm_route (model, provider_id, upstream_model, priority, weight, max_batch, enabled, position)
VALUES (
  sqlc.arg(model), sqlc.arg(provider_id), sqlc.arg(upstream_model), sqlc.arg(priority),
  sqlc.arg(weight), sqlc.arg(max_batch), sqlc.arg(enabled), sqlc.arg(position)
);

-- name: DeleteLLMModel :execrows
DELETE FROM llm_model WHERE name = sqlc.arg(name);
