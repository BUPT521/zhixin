-- 嵌入向量缓存（internal/store/schema.sql 的 embedding_cache，ADR-0030）。
--
-- 参数一律用 sqlc.arg(名字)：同一个名字在一句里出现多次也只绑一次。哈希、维度
-- 与向量按数组批量传入：一次索引刷新的嵌入可能有 256 条，逐条写库太慢。

-- name: LookupEmbeddingCache :many
-- 命中时同一条语句更新 last_used_at：查找与“最近使用”只花一次往返，上限清理
-- 按 last_used_at 淘汰时，刚命中的行排在后面。只返回本账号的行。
UPDATE embedding_cache
SET last_used_at = now()
WHERE user_id = sqlc.arg(user_id)
  AND model = sqlc.arg(model)
  AND text_hash = ANY(sqlc.arg(hashes)::text[])
RETURNING text_hash, dim, vector;

-- name: InsertEmbeddingCaches :exec
-- 重复写入不覆盖已有的行：同一段文本已经算过的向量保持原值，缓存里不会出现
-- 同一哈希对应两个不同向量空间的行。
INSERT INTO embedding_cache (user_id, model, text_hash, dim, vector)
SELECT sqlc.arg(user_id), sqlc.arg(model), t.hash, d.dim, v.vector
FROM unnest(sqlc.arg(hashes)::text[]) WITH ORDINALITY AS t(hash, position)
JOIN unnest(sqlc.arg(dims)::integer[]) WITH ORDINALITY AS d(dim, position) ON d.position = t.position
JOIN unnest(sqlc.arg(vectors)::bytea[]) WITH ORDINALITY AS v(vector, position) ON v.position = t.position
ON CONFLICT (user_id, model, text_hash) DO NOTHING;

-- name: EmbeddingCacheBytes :one
-- 一个账号当前保存的向量字节合计，与上限比较；没有行时是 0。
SELECT COALESCE(sum(octet_length(vector)), 0)::bigint AS bytes
FROM embedding_cache
WHERE user_id = sqlc.arg(user_id);

-- name: OldestEmbeddingCacheSizes :many
-- 这个账号最久未用的若干行的字节数。上限清理按这些数算出要删几行，避免一批删
-- 掉远超所需的缓存。
SELECT octet_length(vector)::bigint AS bytes
FROM embedding_cache
WHERE user_id = sqlc.arg(user_id)
ORDER BY last_used_at ASC
LIMIT sqlc.arg(row_limit);

-- name: DeleteOldestEmbeddingCache :execrows
-- 删除这个账号最久未用的若干行。行数由上限清理按字节算好，删完重新求和。
DELETE FROM embedding_cache AS c
WHERE (c.user_id, c.model, c.text_hash) IN (
  SELECT e.user_id, e.model, e.text_hash
  FROM embedding_cache AS e
  WHERE e.user_id = sqlc.arg(user_id)
  ORDER BY e.last_used_at ASC
  LIMIT sqlc.arg(row_limit)
);

-- name: DeleteEmbeddingCacheForModel :exec
DELETE FROM embedding_cache WHERE model = sqlc.arg(model);

-- name: DeleteEmbeddingCacheForUser :exec
DELETE FROM embedding_cache WHERE user_id = sqlc.arg(user_id);

-- name: EmbeddingCacheGeneration :one
-- 账号当前的缓存代次；还没有行时是 0。写入缓存前与清除时都用这一句，写入方在
-- 自己的事务里读，清除方加一，两边对不上就说明中间清过一次（ADR-0037）。
SELECT COALESCE(
  (SELECT generation FROM embedding_cache_generation WHERE user_id = sqlc.arg(user_id)),
  0
)::bigint;

-- name: BumpEmbeddingCacheGeneration :exec
-- 清除云端数据时把代次加一，之后旧请求写缓存会被写入方的事务拒掉。
INSERT INTO embedding_cache_generation (user_id, generation)
VALUES (sqlc.arg(user_id), 1)
ON CONFLICT (user_id)
DO UPDATE SET generation = embedding_cache_generation.generation + 1;
