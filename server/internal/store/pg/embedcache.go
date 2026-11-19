package pg

import (
	"context"
	"fmt"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// EmbeddingCache 是 llmproxy.EmbeddingCache 的 PostgreSQL 实现，与 Store 共用
// 连接池与 sqlc 查询（ADR-0030）。
//
// 单独一个类型而不是把方法挂在 Store 上，与 BlobStore 同理：Store 已经有其他
// 存储接口的 Put、DeleteModel 与 DeleteUser，语义各不相同，同名方法在同一个
// 类型上无法共存。
type EmbeddingCache struct {
	store *Store
	// limit 是每账号的向量字节上限，由 llmproxy 装配时经 SetEmbeddingCacheLimit
	// 注入一次，运行期间不再修改，因此不加锁。
	limit int64
}

// NewEmbeddingCache 建立嵌入向量缓存；它不访问网络，连通性由 Store 的 Ping 负责。
func NewEmbeddingCache(store *Store) *EmbeddingCache { return &EmbeddingCache{store: store} }

var (
	_ llmproxy.EmbeddingCache = (*EmbeddingCache)(nil)
	_ interface {
		SetEmbeddingCacheLimit(bytes int64)
	} = (*EmbeddingCache)(nil)
)

// cacheRowBatch 是一次上限清理最多读取与删除的行数。清理按字节算出确切要删的
// 行数，删完重新求和，不会一次删掉远超所需的缓存。
const cacheRowBatch = 1024

// SetEmbeddingCacheLimit 注入每账号的缓存字节上限（ADR-0030）。
func (c *EmbeddingCache) SetEmbeddingCacheLimit(bytes int64) { c.limit = bytes }

// Lookup 按账号与模型查找向量，命中的行在同一条语句里更新 last_used_at。只碰
// 本账号的行，别的账号存过同样的文本也查不到。
func (c *EmbeddingCache) Lookup(ctx context.Context, userID, model string, hashes []string) ([]llmproxy.CachedVector, error) {
	if len(hashes) == 0 {
		return nil, nil
	}
	rows, err := c.store.q.LookupEmbeddingCache(ctx, db.LookupEmbeddingCacheParams{
		UserID: userID, Model: model, Hashes: hashes,
	})
	if err != nil {
		return nil, fmt.Errorf("pg: 查找嵌入缓存失败: %w", err)
	}
	out := make([]llmproxy.CachedVector, 0, len(rows))
	for _, r := range rows {
		out = append(out, llmproxy.CachedVector{Hash: r.TextHash, Dim: int(r.Dim), Vector: r.Vector})
	}
	return out, nil
}

// Put 批量写入向量并执行上限清理。插入与清理在同一个事务里，事务开头锁住账号的
// 清理键：同一账号的并发写入排队，淘汰读到的字节数不会因为另一批插入而失真。
// 重复写入由 ON CONFLICT DO NOTHING 跳过，已经算过的行保持原值。
func (c *EmbeddingCache) Put(ctx context.Context, userID, model string, items []llmproxy.CachedVector) error {
	params := db.InsertEmbeddingCachesParams{UserID: userID, Model: model}
	for _, item := range items {
		if !cacheableRow(item) {
			continue
		}
		params.Hashes = append(params.Hashes, item.Hash)
		params.Dims = append(params.Dims, int32(item.Dim))
		params.Vectors = append(params.Vectors, item.Vector)
	}
	if len(params.Hashes) == 0 {
		return nil
	}
	tx, err := c.store.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("pg: 开始嵌入缓存事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "embedding_cache:"+userID); err != nil {
		return fmt.Errorf("pg: 锁定账号的嵌入缓存失败: %w", err)
	}
	q := c.store.q.WithTx(tx)
	if err := q.InsertEmbeddingCaches(ctx, params); err != nil {
		return fmt.Errorf("pg: 写入嵌入缓存失败: %w", err)
	}
	if err := trimEmbeddingCache(ctx, q, userID, c.limit); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// trimEmbeddingCache 按 last_used_at 删除最久未用的行，直到这个账号的向量字节
// 回到上限之内。先读出最久未用的若干行的字节数，算出删到刚好不超上限需要几行，
// 再一次删掉；刚写入与刚命中的行时间最新，排在后面不被删掉。
func trimEmbeddingCache(ctx context.Context, q *db.Queries, userID string, limit int64) error {
	if limit <= 0 {
		return nil
	}
	for {
		used, err := q.EmbeddingCacheBytes(ctx, userID)
		if err != nil {
			return fmt.Errorf("pg: 读取嵌入缓存字节失败: %w", err)
		}
		if used <= limit {
			return nil
		}
		sizes, err := q.OldestEmbeddingCacheSizes(ctx, db.OldestEmbeddingCacheSizesParams{
			UserID: userID, RowLimit: cacheRowBatch,
		})
		if err != nil {
			return fmt.Errorf("pg: 读取最久未用的缓存行失败: %w", err)
		}
		if len(sizes) == 0 {
			return nil // 已经没有行可删，退出而不是空转
		}
		excess := used - limit
		var removed int64
		rows := 0
		for _, size := range sizes {
			rows++
			removed += size
			if removed >= excess {
				break
			}
		}
		deleted, err := q.DeleteOldestEmbeddingCache(ctx, db.DeleteOldestEmbeddingCacheParams{
			UserID: userID, RowLimit: int32(rows),
		})
		if err != nil {
			return fmt.Errorf("pg: 清理嵌入缓存失败: %w", err)
		}
		if deleted == 0 {
			return nil
		}
	}
}

// DeleteModel 删除一个对外模型的全部缓存行；管理后台删除模型或改变维度时调用，
// 旧名字再次出现时不会命中上一个向量空间的向量。
func (c *EmbeddingCache) DeleteModel(ctx context.Context, model string) error {
	if err := c.store.q.DeleteEmbeddingCacheForModel(ctx, model); err != nil {
		return fmt.Errorf("pg: 删除模型的嵌入缓存失败: %w", err)
	}
	return nil
}

// DeleteUser 删除一个账号的全部缓存行；DELETE /v1/cloud 的清除顺序里调用。
// 账号删除时这些行也随外键级联删除。
func (c *EmbeddingCache) DeleteUser(ctx context.Context, userID string) error {
	if err := c.store.q.DeleteEmbeddingCacheForUser(ctx, userID); err != nil {
		return fmt.Errorf("pg: 删除账号的嵌入缓存失败: %w", err)
	}
	return nil
}

// cacheableRow 只写形状正确的行：维度为正、向量长度等于维度乘二、哈希长度与
// SHA-256 的十六进制表示一致。处理器已经保证这些条件，这里再挡一次，坏数据
// 不会让整批写入失败。
func cacheableRow(item llmproxy.CachedVector) bool {
	return len(item.Hash) == 64 && item.Dim > 0 && len(item.Vector) == item.Dim*2
}
