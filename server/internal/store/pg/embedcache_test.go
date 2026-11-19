package pg

import (
	"bytes"
	"context"
	"fmt"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

// cacheHash 生成一个 64 位小写十六进制的测试哈希，与 schema 的 CHECK 约束一致。
func cacheHash(n int) string { return fmt.Sprintf("%064x", n) }

// cacheVector 生成一段 FP16 字节；测试只核对原样往返，不关心数值。
func cacheVector(dim int, seed byte) []byte {
	v := make([]byte, dim*2)
	for i := range v {
		v[i] = seed
	}
	return v
}

// TestPostgresEmbeddingCache 覆盖 ADR-0030 第一步的存储行为：写入与查找、重复
// 写入不覆盖、按账号与按模型隔离、模型删除、删号级联与字节上限淘汰。
func TestPostgresEmbeddingCache(t *testing.T) {
	st := newTestStore(t)
	cache := NewEmbeddingCache(st)
	cache.SetEmbeddingCacheLimit(1 << 20)
	ctx := context.Background()

	for _, id := range []string{"u1", "u2"} {
		if err := st.CreateUser(ctx, auth.User{ID: id, Email: id + "@b.cn", PasswordHash: "h"}); err != nil {
			t.Fatalf("create user %s: %v", id, err)
		}
	}
	h1, h2, h3 := cacheHash(1), cacheHash(2), cacheHash(3)
	items := []llmproxy.CachedVector{
		{Hash: h1, Dim: 2, Vector: cacheVector(2, 1)},
		{Hash: h2, Dim: 2, Vector: cacheVector(2, 2)},
	}
	if err := cache.Put(ctx, "u1", "m", items); err != nil {
		t.Fatalf("put: %v", err)
	}

	// 命中两个、未命中一个：未命中不是错误，也不会出现在结果里。
	rows, err := cache.Lookup(ctx, "u1", "m", []string{h1, h2, h3})
	if err != nil || len(rows) != 2 {
		t.Fatalf("lookup: %d %v", len(rows), err)
	}
	got := map[string]llmproxy.CachedVector{}
	for _, r := range rows {
		got[r.Hash] = r
	}
	if !bytes.Equal(got[h1].Vector, items[0].Vector) || got[h1].Dim != 2 {
		t.Fatalf("h1 往返不对：%+v", got[h1])
	}

	// 重复写入不覆盖：同一哈希换一个维度写入，读到的还是第一份。
	if err := cache.Put(ctx, "u1", "m", []llmproxy.CachedVector{{Hash: h1, Dim: 1, Vector: []byte{9, 9}}}); err != nil {
		t.Fatalf("duplicate put: %v", err)
	}
	rows, err = cache.Lookup(ctx, "u1", "m", []string{h1})
	if err != nil || len(rows) != 1 || rows[0].Dim != 2 || !bytes.Equal(rows[0].Vector, cacheVector(2, 1)) {
		t.Fatalf("重复写入覆盖了已有的行：%+v %v", rows, err)
	}

	// 按账号隔离：另一个账号查不到同样的哈希。
	if rows, err := cache.Lookup(ctx, "u2", "m", []string{h1}); err != nil || len(rows) != 0 {
		t.Fatalf("跨账号命中：%d %v", len(rows), err)
	}

	// 按模型隔离，删模型只清这个模型的行。
	if err := cache.Put(ctx, "u1", "m2", []llmproxy.CachedVector{{Hash: h1, Dim: 2, Vector: cacheVector(2, 3)}}); err != nil {
		t.Fatalf("put m2: %v", err)
	}
	if err := cache.DeleteModel(ctx, "m"); err != nil {
		t.Fatalf("delete model: %v", err)
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{h1}); len(rows) != 0 {
		t.Fatalf("删模型之后仍有残留：%+v", rows)
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m2", []string{h1}); len(rows) != 1 {
		t.Fatalf("删模型误伤了别的模型：%d", len(rows))
	}

	// 字节上限：8 字节只能放两行，写入第三行时删掉最久未用的一行。
	cache.SetEmbeddingCacheLimit(8)
	if err := cache.Put(ctx, "u2", "m", []llmproxy.CachedVector{
		{Hash: h1, Dim: 2, Vector: cacheVector(2, 4)},
		{Hash: h2, Dim: 2, Vector: cacheVector(2, 5)},
	}); err != nil {
		t.Fatalf("put at limit: %v", err)
	}
	if err := cache.Put(ctx, "u2", "m", []llmproxy.CachedVector{{Hash: h3, Dim: 2, Vector: cacheVector(2, 6)}}); err != nil {
		t.Fatalf("put over limit: %v", err)
	}
	used, err := st.q.EmbeddingCacheBytes(ctx, "u2")
	if err != nil || used > 8 {
		t.Fatalf("上限清理之后应不超过 8 字节：used=%d err=%v", used, err)
	}
	rows, err = cache.Lookup(ctx, "u2", "m", []string{h1, h2, h3})
	if err != nil || len(rows) != 2 {
		t.Fatalf("上限清理应删到两行：%d %v", len(rows), err)
	}
	found := false
	for _, r := range rows {
		found = found || r.Hash == h3
	}
	if !found {
		t.Fatalf("刚写入的行被删掉了：%+v", rows)
	}

	// 删号级联：账号行删除之后缓存行跟着消失。
	if err := st.DeleteUser(ctx, "u2"); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	if rows, err := cache.Lookup(ctx, "u2", "m", []string{h1, h2, h3}); err != nil || len(rows) != 0 {
		t.Fatalf("删号之后缓存应级联删除：%d %v", len(rows), err)
	}
}
