package llmproxy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// newCacheTestServer 装配一个带嵌入模型的测试服务、一份进程内缓存与一个已
// 登录的账号。嵌入来源按输入编号返回向量，第 0 个分量是固定值 1，第 1 个
// 分量是输入的编号。
func newCacheTestServer(t *testing.T) (*testEnv, *MemoryEmbeddingCache, auth.Tokens) {
	t.Helper()
	src := newEmbedSource(t, 1, 4)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "sf", src.URL, "sk-sf")
		putModel(t, c, ModelRecord{Name: "zhixin-embed", Kind: KindEmbedding, Dimensions: 4, Routes: []Route{
			{ProviderID: "sf", UpstreamModel: "BAAI/bge-m3", MaxBatch: 2},
		}})
		putModel(t, c, ModelRecord{Name: "chat-x", Kind: KindChat, Routes: []Route{
			{ProviderID: "sf", UpstreamModel: "deepseek-flash"},
		}})
	})
	cache := NewMemoryEmbeddingCache()
	env.proxy.SetEmbeddingCache(cache)
	tokens, err := env.authSvc.Register(context.Background(), "cache@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	return env, cache, tokens
}

// lookupPayload 解出查找接口的响应：每个哈希一条，向量按 FP16 解成浮点数。
type lookupPayload struct {
	Model      string `json:"model"`
	Dimensions *int   `json:"dimensions"`
	Vectors    []struct {
		Hash      string `json:"hash"`
		Embedding string `json:"embedding"`
	} `json:"vectors"`
	vectors map[string][]float32
}

func decodeLookup(t *testing.T, p *lookupPayload) map[string][]float32 {
	t.Helper()
	p.vectors = make(map[string][]float32, len(p.Vectors))
	for _, v := range p.Vectors {
		raw, err := base64.StdEncoding.DecodeString(v.Embedding)
		if err != nil {
			t.Fatalf("embedding 不是 base64：%v", err)
		}
		vec, err := decodeVector(raw)
		if err != nil {
			t.Fatalf("embedding 不是 FP16：%v", err)
		}
		p.vectors[v.Hash] = vec
	}
	return p.vectors
}

// putCache 按账号当前的代次写入向量，等价于一次请求在读到代次之后才写回缓存。
// 用例里没有清除时代次是 0，读取一次让调用点不必重复写这个值。
func putCache(t *testing.T, cache *MemoryEmbeddingCache, userID, model string, items []CachedVector) {
	t.Helper()
	ctx := context.Background()
	generation, err := cache.Generation(ctx, userID)
	if err != nil {
		t.Fatalf("读取缓存代次：%v", err)
	}
	if err := cache.Put(ctx, userID, model, items, generation); err != nil {
		t.Fatalf("写入缓存：%v", err)
	}
}

// postEmbeddings 发一次嵌入请求，可选带上缓存请求头。
func postEmbeddings(t *testing.T, env *testEnv, token string, texts []string, cacheHeader bool) int {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"model": "zhixin-embed", "input": texts})
	var headers map[string]string
	if cacheHeader {
		headers = map[string]string{embeddingCacheHeader: "1"}
	}
	resp := env.c.Do(http.MethodPost, "/v1/llm/embeddings", token, bytes.NewReader(body), headers)
	defer resp.Body.Close()
	return resp.StatusCode
}

// TestEmbeddingCacheWriteRequiresHeaderAndLookupReturnsVectors 守住第一步的
// 主路径：不带缓存头的嵌入不写缓存；带头的写入之后，查找接口返回可解码的
// FP16 向量与维度，未命中不报错。
func TestEmbeddingCacheWriteRequiresHeaderAndLookupReturnsVectors(t *testing.T) {
	env, cache, tokens := newCacheTestServer(t)
	texts := inputs(3)
	hashes := make([]string, len(texts))
	for i, text := range texts {
		hashes[i] = textHash(text)
	}

	if code := postEmbeddings(t, env, tokens.AccessToken, texts, false); code != http.StatusOK {
		t.Fatalf("embeddings without the cache header: %d", code)
	}
	if rows, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", hashes); err != nil || len(rows) != 0 {
		t.Fatalf("不带请求头不应写缓存：rows=%d err=%v", len(rows), err)
	}

	if code := postEmbeddings(t, env, tokens.AccessToken, texts, true); code != http.StatusOK {
		t.Fatalf("embeddings with the cache header: %d", code)
	}

	// 三个已知哈希加一个没算过的：只返回命中的三条。
	request := append(append([]string{}, hashes...), textHash("没存过"))
	var out lookupPayload
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings/lookup", tokens.AccessToken,
		map[string]any{"model": "zhixin-embed", "hashes": request}, &out); code != http.StatusOK {
		t.Fatalf("lookup: %d", code)
	}
	if out.Model != "zhixin-embed" || out.Dimensions == nil || *out.Dimensions != 4 {
		t.Fatalf("lookup 元数据：%+v", out)
	}
	vectors := decodeLookup(t, &out)
	if len(vectors) != 3 {
		t.Fatalf("应命中 3 条，得到 %d：%+v", len(vectors), out.Vectors)
	}
	for i, h := range hashes {
		vec, ok := vectors[h]
		if !ok {
			t.Fatalf("第 %d 个哈希没有命中", i)
		}
		// 来源返回 [1, 输入编号, 0, 0]，经过 FP16 之后应原样回来。
		if len(vec) != 4 || vec[0] != 1 || vec[1] != float32(i) {
			t.Fatalf("第 %d 条向量：%v", i, vec)
		}
	}
}

// TestEmbeddingCacheDuplicateWriteKeepsFirstVector 守住“重复写入不覆盖已有的
// 行”：同一哈希第二次写入另一个维度不会改变缓存里的向量。
func TestEmbeddingCacheDuplicateWriteKeepsFirstVector(t *testing.T) {
	env, cache, tokens := newCacheTestServer(t)
	texts := inputs(1)
	if code := postEmbeddings(t, env, tokens.AccessToken, texts, true); code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}
	h := textHash(texts[0])
	first, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", []string{h})
	if err != nil || len(first) != 1 {
		t.Fatalf("首次写入后应命中：%d %v", len(first), err)
	}
	// 直接写一条同哈希、不同维度与向量的行，应被忽略。
	putCache(t, cache, tokens.UserID, "zhixin-embed", []CachedVector{
		{Hash: h, Dim: 2, Vector: []byte{1, 2, 3, 4}},
	})
	again, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", []string{h})
	if err != nil || len(again) != 1 {
		t.Fatalf("重复写入后仍应命中：%d %v", len(again), err)
	}
	if again[0].Dim != first[0].Dim || !bytes.Equal(again[0].Vector, first[0].Vector) {
		t.Fatalf("重复写入覆盖了已有的行：%+v → %+v", first[0], again[0])
	}
}

// TestEmbeddingCacheGateBlocksWrite 守住清除云端数据期间的写入拦截：嵌入照常
// 返回，缓存不新增派生数据。
func TestEmbeddingCacheGateBlocksWrite(t *testing.T) {
	env, cache, tokens := newCacheTestServer(t)
	env.proxy.SetEmbeddingCacheGate(func(context.Context, string) error {
		return errors.New("cloud purge in progress")
	})
	texts := inputs(2)
	if code := postEmbeddings(t, env, tokens.AccessToken, texts, true); code != http.StatusOK {
		t.Fatalf("清除期间嵌入仍应可用：%d", code)
	}
	hashes := []string{textHash(texts[0]), textHash(texts[1])}
	if rows, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", hashes); err != nil || len(rows) != 0 {
		t.Fatalf("清除期间不应写缓存：rows=%d err=%v", len(rows), err)
	}
}

// TestEmbeddingCacheIsolatedByAccount 守住按账号隔离：一个账号算过的文本，另一个
// 账号查不到。
func TestEmbeddingCacheIsolatedByAccount(t *testing.T) {
	env, _, tokens := newCacheTestServer(t)
	other, err := env.authSvc.Register(context.Background(), "other@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	texts := inputs(1)
	if code := postEmbeddings(t, env, tokens.AccessToken, texts, true); code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}
	var out lookupPayload
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings/lookup", other.AccessToken,
		map[string]any{"model": "zhixin-embed", "hashes": []string{textHash(texts[0])}}, &out); code != http.StatusOK {
		t.Fatalf("lookup: %d", code)
	}
	if len(out.Vectors) != 0 {
		t.Fatalf("别的账号不应命中：%+v", out.Vectors)
	}
	if out.Dimensions != nil {
		t.Fatalf("全部未命中时不应带维度：%+v", out.Dimensions)
	}
}

// TestEmbeddingLookupValidation 守住查找接口的请求校验：条数、哈希格式与模型
// 用途都按嵌入接口的现有错误返回。
func TestEmbeddingLookupValidation(t *testing.T) {
	env, _, tokens := newCacheTestServer(t)
	tooMany := make([]string, 9) // baseConfig 的 EmbeddingMaxInputs 是 8
	for i := range tooMany {
		tooMany[i] = textHash(string(rune('a' + i)))
	}
	cases := []struct {
		name string
		body map[string]any
		code int
		want string
	}{
		{"missing hashes", map[string]any{"model": "zhixin-embed"}, http.StatusBadRequest, string(httpx.CodeInvalidRequest)},
		{"empty hashes", map[string]any{"model": "zhixin-embed", "hashes": []string{}}, http.StatusBadRequest, string(httpx.CodeInvalidRequest)},
		{"not an array", map[string]any{"model": "zhixin-embed", "hashes": "abc"}, http.StatusBadRequest, string(httpx.CodeInvalidRequest)},
		{"uppercase hash", map[string]any{"model": "zhixin-embed", "hashes": []string{"9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08"}}, http.StatusBadRequest, string(httpx.CodeInvalidRequest)},
		{"short hash", map[string]any{"model": "zhixin-embed", "hashes": []string{"abc"}}, http.StatusBadRequest, string(httpx.CodeInvalidRequest)},
		{"too many hashes", map[string]any{"model": "zhixin-embed", "hashes": tooMany}, http.StatusBadRequest, string(httpx.CodeInvalidRequest)},
		{"unknown model", map[string]any{"model": "nope", "hashes": []string{textHash("a")}}, http.StatusBadRequest, string(httpx.CodeModelNotAllowed)},
		{"chat model", map[string]any{"model": "chat-x", "hashes": []string{textHash("a")}}, http.StatusBadRequest, string(httpx.CodeModelNotAllowed)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var p testutil.Problem
			if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings/lookup", tokens.AccessToken, tc.body, &p); code != tc.code || p.Code != tc.want {
				t.Fatalf("want %d %s, got %d %+v", tc.code, tc.want, code, p)
			}
		})
	}
}

// TestEmbeddingLookupDoesNotSpendQuota 守住查找不消耗额度：嵌入额度用完之后
// 仍然能查缓存，也不会写新的用量。
func TestEmbeddingLookupDoesNotSpendQuota(t *testing.T) {
	env, cache, tokens := newCacheTestServer(t)
	h := textHash("text-0")
	putCache(t, cache, tokens.UserID, "zhixin-embed", []CachedVector{
		{Hash: h, Dim: 4, Vector: encodeVector([]float32{1, 0, 0, 0})},
	})
	// 把嵌入额度调到 0：额度用完是 429，但查找不走额度。
	env.quota.SetKindLimit(tokens.UserID, KindEmbedding, 1)
	var out lookupPayload
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings/lookup", tokens.AccessToken,
		map[string]any{"model": "zhixin-embed", "hashes": []string{h}}, &out); code != http.StatusOK || len(out.Vectors) != 1 {
		t.Fatalf("lookup: %d %+v", code, out)
	}
	var q struct {
		Used    int64 `json:"embedding_used_tokens"`
		ChatUse int64 `json:"used_tokens"`
	}
	env.c.JSON(http.MethodGet, "/v1/llm/quota", tokens.AccessToken, nil, &q)
	if q.Used != 0 || q.ChatUse != 0 {
		t.Fatalf("查找不应消耗额度：%+v", q)
	}
}

// TestEmbeddingLookupUsesRowDimensionsWhenModelHasNone 守住模型没有配置维度时，
// 响应取命中行的维度。
func TestEmbeddingLookupUsesRowDimensionsWhenModelHasNone(t *testing.T) {
	src := newEmbedSource(t, 1, 3)
	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "sf", src.URL, "sk-sf")
		putModel(t, c, ModelRecord{Name: "no-dim", Kind: KindEmbedding, Routes: []Route{
			{ProviderID: "sf", UpstreamModel: "BAAI/bge-m3"},
		}})
	})
	cache := NewMemoryEmbeddingCache()
	env.proxy.SetEmbeddingCache(cache)
	tokens, err := env.authSvc.Register(context.Background(), "nodim@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	h := textHash("text-0")
	putCache(t, cache, tokens.UserID, "no-dim", []CachedVector{
		{Hash: h, Dim: 3, Vector: encodeVector([]float32{0, 1, 2})},
	})
	var out lookupPayload
	if code := env.c.JSON(http.MethodPost, "/v1/llm/embeddings/lookup", tokens.AccessToken,
		map[string]any{"model": "no-dim", "hashes": []string{h}}, &out); code != http.StatusOK || out.Dimensions == nil || *out.Dimensions != 3 {
		t.Fatalf("lookup: %d %+v", code, out)
	}
}

// TestMemoryEmbeddingCacheEvictsLeastRecentlyUsed 守住上限淘汰：超过字节上限时
// 删最久未用的行，刚命中的行留下。
func TestMemoryEmbeddingCacheEvictsLeastRecentlyUsed(t *testing.T) {
	cache := NewMemoryEmbeddingCache()
	cache.SetEmbeddingCacheLimit(12) // 三行 4 字节
	ctx := context.Background()
	row := func(tag byte) CachedVector {
		return CachedVector{Hash: textHash(string(rune(tag))), Dim: 2, Vector: []byte{tag, tag, tag, tag}}
	}
	for _, tag := range []byte{'1', '2', '3'} {
		putCache(t, cache, "u1", "m", []CachedVector{row(tag)})
	}
	if got := cache.Bytes(); got != 12 {
		t.Fatalf("bytes = %d, want 12", got)
	}
	h1 := textHash("1")
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{h1}); len(rows) != 1 {
		t.Fatal("第一行应在缓存里")
	}
	putCache(t, cache, "u1", "m", []CachedVector{row('4')})
	if got := cache.Bytes(); got > 12 {
		t.Fatalf("淘汰之后 bytes = %d，超过上限", got)
	}
	// 第二行最久没用（第一行刚查过），应被删掉；其余三行还在。
	for _, tag := range []string{"1", "3", "4"} {
		if rows, _ := cache.Lookup(ctx, "u1", "m", []string{textHash(tag)}); len(rows) != 1 {
			t.Fatalf("第 %s 行不应被删", tag)
		}
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{textHash("2")}); len(rows) != 0 {
		t.Fatal("最久未用的第二行应被淘汰")
	}
	// 删号与删模型都要清干净。
	if err := cache.DeleteUser(ctx, "u1"); err != nil || cache.Bytes() != 0 {
		t.Fatalf("delete user: bytes=%d err=%v", cache.Bytes(), err)
	}
}

// TestMemoryEmbeddingCachePurgeDropsStaleWrite 守住代次的内存实现语义：清除把
// 代次加一并删行，清除之前读到的代次写不进去，按新代次写入正常。
func TestMemoryEmbeddingCachePurgeDropsStaleWrite(t *testing.T) {
	cache := NewMemoryEmbeddingCache()
	ctx := context.Background()
	h := textHash("stale")
	row := CachedVector{Hash: h, Dim: 2, Vector: []byte{1, 2, 3, 4}}

	generation, err := cache.Generation(ctx, "u1")
	if err != nil || generation != 0 {
		t.Fatalf("新账号的代次应是 0：%d %v", generation, err)
	}
	if err := cache.Put(ctx, "u1", "m", []CachedVector{row}, generation); err != nil {
		t.Fatalf("首次写入：%v", err)
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{h}); len(rows) != 1 {
		t.Fatal("首次写入后应命中")
	}

	if err := cache.PurgeUser(ctx, "u1"); err != nil {
		t.Fatalf("清除：%v", err)
	}
	if after, err := cache.Generation(ctx, "u1"); err != nil || after != generation+1 {
		t.Fatalf("清除之后代次应加一：%d %v", after, err)
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{h}); len(rows) != 0 {
		t.Fatalf("清除之后不应命中：%+v", rows)
	}
	// 用清除之前读到的代次写入：不报错，但也不写。
	if err := cache.Put(ctx, "u1", "m", []CachedVector{row}, generation); err != nil {
		t.Fatalf("过期代次的写入不应报错：%v", err)
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{h}); len(rows) != 0 {
		t.Fatalf("过期代次的写入不应落库：%+v", rows)
	}
	// 按新代次写入正常。
	if err := cache.Put(ctx, "u1", "m", []CachedVector{row}, generation+1); err != nil {
		t.Fatalf("新代次写入：%v", err)
	}
	if rows, _ := cache.Lookup(ctx, "u1", "m", []string{h}); len(rows) != 1 {
		t.Fatalf("新代次写入后应命中：%d", len(rows))
	}
}

// TestEmbeddingCachePurgeDuringEmbeddingDropsWrite 守住 ADR-0037 的竞争：请求在
// 调用来源之前读到代次，来源返回之前清除云端数据完成，这次请求算出的向量在
// 写回时对不上代次而被丢弃；清除之后的新请求按新代次正常写入。
func TestEmbeddingCachePurgeDuringEmbeddingDropsWrite(t *testing.T) {
	// 来源收到请求之后停住，等用例在中间完成一次清除再返回。
	reached := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		once.Do(func() { close(reached) })
		<-release
		var body struct {
			Model string   `json:"model"`
			Input []string `json:"input"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		data := make([]string, 0, len(body.Input))
		for i := range body.Input {
			data = append(data, fmt.Sprintf(`{"object":"embedding","index":%d,"embedding":[1,%d,0,0]}`, i, i))
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"object":"list","model":%q,"data":[%s],"usage":{"prompt_tokens":%d,"total_tokens":%d}}`,
			body.Model, strings.Join(data, ","), 3*len(body.Input), 3*len(body.Input))
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "sf", upstream.URL, "sk-sf")
		putModel(t, c, ModelRecord{Name: "zhixin-embed", Kind: KindEmbedding, Dimensions: 4, Routes: []Route{
			{ProviderID: "sf", UpstreamModel: "BAAI/bge-m3"},
		}})
	})
	cache := NewMemoryEmbeddingCache()
	env.proxy.SetEmbeddingCache(cache)
	tokens, err := env.authSvc.Register(context.Background(), "race@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	texts := inputs(2)

	done := make(chan int, 1)
	go func() { done <- postEmbeddings(t, env, tokens.AccessToken, texts, true) }()
	<-reached
	// 请求已经读到代次并在等来源，这时完成一次清除。
	if err := cache.PurgeUser(context.Background(), tokens.UserID); err != nil {
		t.Fatalf("purge: %v", err)
	}
	close(release)
	if code := <-done; code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}

	hashes := []string{textHash(texts[0]), textHash(texts[1])}
	if rows, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", hashes); err != nil || len(rows) != 0 {
		t.Fatalf("清除之前发出的请求不应写回缓存：rows=%d err=%v", len(rows), err)
	}
	// 清除之后的请求按新的代次写入，正常命中。
	if code := postEmbeddings(t, env, tokens.AccessToken, texts, true); code != http.StatusOK {
		t.Fatalf("embeddings after purge: %d", code)
	}
	if rows, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", hashes); err != nil || len(rows) != 2 {
		t.Fatalf("清除之后的请求应写入缓存：rows=%d err=%v", len(rows), err)
	}
}

// failingGenerationCache 让代次读取失败，用来覆盖“读不到代次就不写缓存”的取舍。
type failingGenerationCache struct{ *MemoryEmbeddingCache }

func (failingGenerationCache) Generation(context.Context, string) (int64, error) {
	return 0, errors.New("代次读取失败")
}

// TestEmbeddingCacheSkipsWriteWhenGenerationUnreadable 守住读不到代次时的行为：
// 嵌入照常返回，这次不写缓存；没有可比较的代次时写入可能把清除之前的向量写回。
func TestEmbeddingCacheSkipsWriteWhenGenerationUnreadable(t *testing.T) {
	env, cache, tokens := newCacheTestServer(t)
	env.proxy.SetEmbeddingCache(failingGenerationCache{cache})
	texts := inputs(2)
	if code := postEmbeddings(t, env, tokens.AccessToken, texts, true); code != http.StatusOK {
		t.Fatalf("代次读不到时嵌入仍应可用：%d", code)
	}
	hashes := []string{textHash(texts[0]), textHash(texts[1])}
	if rows, err := cache.Lookup(context.Background(), tokens.UserID, "zhixin-embed", hashes); err != nil || len(rows) != 0 {
		t.Fatalf("读不到代次时不应写缓存：rows=%d err=%v", len(rows), err)
	}
}

// TestTextHashIsSHA256OfUTF8Bytes 守住哈希口径：UTF-8 字节的 SHA-256 小写十六
// 进制，与客户端 Dart 侧算出来的一致。
func TestTextHashIsSHA256OfUTF8Bytes(t *testing.T) {
	sum := sha256.Sum256([]byte("abc"))
	want := hex.EncodeToString(sum[:])
	if got := textHash("abc"); got != want || got != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
		t.Fatalf("textHash(abc) = %s", got)
	}
	if textHash("知新") == textHash("知新x") || !validTextHash(textHash("知新")) {
		t.Fatal("中文文本的哈希不对")
	}
	// 大小写、长度与非法字符都拒绝。
	for _, bad := range []string{"", "abc", strings.ToUpper(want), want + "0", "zz" + want[2:]} {
		if validTextHash(bad) {
			t.Fatalf("%q 应被判为不合法的哈希", bad)
		}
	}
	if !validTextHash(want) {
		t.Fatalf("%q 应该是合法哈希", want)
	}
}

// TestFloat16RoundTrip 握住 FP16 编码：已知位模式、舍入与还原。
func TestFloat16RoundTrip(t *testing.T) {
	cases := []struct {
		in   float32
		bits uint16
	}{
		{0, 0x0000},
		{1, 0x3c00},
		{-1, 0xbc00},
		{0.5, 0x3800},
		{2, 0x4000},
		{65504, 0x7bff},
		{1e-5, 0x00a8},
	}
	for _, tc := range cases {
		if got := float32ToFloat16(tc.in); got != tc.bits {
			t.Fatalf("float32ToFloat16(%v) = %#04x, want %#04x", tc.in, got, tc.bits)
		}
	}
	values := []float32{0, 0.1, -0.25, 3.5, -100.75, 1e-3}
	raw := encodeVector(values)
	if len(raw) != len(values)*2 {
		t.Fatalf("FP16 向量应有 %d 字节，得到 %d", len(values)*2, len(raw))
	}
	back, err := decodeVector(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	for i, v := range values {
		if diff := math.Abs(float64(back[i] - v)); diff > math.Abs(float64(v))*0.001+1e-6 {
			t.Fatalf("第 %d 个分量往返偏差过大：%v → %v", i, v, back[i])
		}
	}
	if _, err := decodeVector([]byte{1, 2, 3}); err == nil {
		t.Fatal("奇数长度应报错")
	}
}

// TestParseEmbeddingFormats 守住提供方两种向量格式的解码：默认的浮点数组与
// encoding_format=base64 时的小端序 FP32 base64。
func TestParseEmbeddingFormats(t *testing.T) {
	arr, err := parseEmbedding(json.RawMessage(`[1, -2.5, 3]`))
	if err != nil || len(arr) != 3 || arr[1] != -2.5 {
		t.Fatalf("数组格式：%v %v", arr, err)
	}
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:], math.Float32bits(0.5))
	binary.LittleEndian.PutUint32(buf[4:], math.Float32bits(-4))
	encoded, _ := json.Marshal(base64.StdEncoding.EncodeToString(buf))
	b64, err := parseEmbedding(encoded)
	if err != nil || len(b64) != 2 || b64[0] != 0.5 || b64[1] != -4 {
		t.Fatalf("base64 格式：%v %v", b64, err)
	}
	for _, bad := range []string{`null`, `{}`, `"***"`, `[1, x]`} {
		if _, err := parseEmbedding(json.RawMessage(bad)); err == nil {
			t.Fatalf("%s 应解码失败", bad)
		}
	}
}
