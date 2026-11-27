package llmproxy

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// embeddingCacheHeader 是客户端在索引刷新的嵌入请求上带的头：值为 1 时服务端
// 把这次的结果写进缓存。检索查询的嵌入不带这个头，未登录、同步关闭与自填 key
// 直连的用户也不带，服务端因此不会给这些用户留下派生数据（ADR-0030 决定第 3 条）。
const embeddingCacheHeader = "X-Zhixin-Embedding-Cache"

// backgroundWorkload 报告这次请求是不是可以等的后台批次：客户端用请求头
// X-Zhixin-Workload: batch 标明材料导入、索引重建与补算，其余取值与缺省都按前台
// 处理，旧客户端因此不受限制。后台批次只能用没有留给前台的那部分并发名额与
// 内存，占不到时返回 429，由客户端稍后重试。
func backgroundWorkload(workload *string) bool {
	return workload != nil && strings.EqualFold(strings.TrimSpace(*workload), "batch")
}

// embeddingCacheTimeout 是一次缓存读写的时限。缓存是派生数据，写失败只是下次
// 重新嵌入，不该拖住请求。
const embeddingCacheTimeout = 15 * time.Second

// EmbeddingLookup 回答客户端对一批文本哈希的向量查找。鉴权、未验证邮箱与并发
// 上限与嵌入接口相同；查找不消耗额度，也不写 llm_usage。响应只含命中的条目，
// 全部未命中不是错误，客户端据此只嵌入剩下的文本。
func (p *Proxy) EmbeddingLookup(w http.ResponseWriter, r *http.Request, params api.PostV1LlmEmbeddingsLookupParams) {
	userID := auth.MustPrincipal(r.Context()).UserID
	done, ok := p.beginRequest(w, r, userID, backgroundWorkload(params.XZhixinWorkload))
	if !ok {
		return
	}
	defer done()
	fields, ok := p.readBody(w, r)
	if !ok {
		return
	}
	m := p.findModel(w, r, fields, KindEmbedding)
	if m == nil {
		return
	}
	hashes, err := lookupHashes(fields["hashes"], p.cfg.EmbeddingMaxInputs)
	if err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), embeddingCacheTimeout)
	defer cancel()
	var cached []CachedVector
	if p.cache != nil {
		cached, err = p.cache.Lookup(ctx, userID, m.Name, hashes)
		if err != nil {
			httpx.WriteInternal(w, r, p.log, err)
			return
		}
	}
	out := api.EmbeddingLookupResult{Model: m.Name, Vectors: make([]api.EmbeddingLookupVector, 0, len(cached))}
	// 维度以模型配置为准；模型没有配置维度时取第一条命中行，客户端据此核对
	// 解码出来的长度。全部未命中时省略，没有可以说明的维度。
	var dimensions int
	for _, v := range cached {
		if v.Dim <= 0 || len(v.Vector) != v.Dim*2 {
			continue // 防御性跳过：行损坏时宁可不命中，也不给客户端一个错的长度
		}
		if len(out.Vectors) == 0 {
			dimensions = m.Dimensions
			if dimensions == 0 {
				dimensions = v.Dim
			}
		}
		out.Vectors = append(out.Vectors, api.EmbeddingLookupVector{
			Hash:      v.Hash,
			Embedding: base64.StdEncoding.EncodeToString(v.Vector),
		})
	}
	if dimensions > 0 {
		out.Dimensions = &dimensions
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// lookupHashes 校验并去重请求里的哈希。单次条数与嵌入接口一致；哈希必须是
// 64 位小写十六进制，否则客户端与服务端会算出两种键，同样的文本永远命不中。
func lookupHashes(raw json.RawMessage, max int) ([]string, error) {
	if len(raw) == 0 {
		return nil, errors.New("hashes is required")
	}
	var list []string
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, errors.New("hashes must be an array of SHA-256 hex strings")
	}
	if len(list) == 0 {
		return nil, errors.New("hashes must not be empty")
	}
	if len(list) > max {
		return nil, fmt.Errorf("at most %d hashes per request", max)
	}
	out := make([]string, 0, len(list))
	seen := make(map[string]bool, len(list))
	for _, h := range list {
		if !httpx.ValidSHA256(h) {
			return nil, errors.New("hashes must be 64 lowercase hex characters")
		}
		if !seen[h] {
			seen[h] = true
			out = append(out, h)
		}
	}
	return out, nil
}

// embeddingCacheGeneration 在嵌入请求开始、调用来源之前读一次账号的缓存代次。
// 写入时缓存实现会拿它与自己事务里的当前代次比较，不一致就丢弃这次写入，清除
// 之前发出的请求因此写不回旧向量（ADR-0037）。
//
// 这次不写缓存的两种情况返回 false：没有注入缓存或客户端没有带缓存请求头，
// 以及代次读取失败。第二种情况记一条日志后跳过写入，嵌入本身照常返回。
func (p *Proxy) embeddingCacheGeneration(ctx context.Context, r *http.Request, userID string) (int64, bool) {
	if p.cache == nil || r.Header.Get(embeddingCacheHeader) != "1" {
		return 0, false
	}
	cacheCtx, cancel := context.WithTimeout(ctx, embeddingCacheTimeout)
	defer cancel()
	generation, err := p.cache.Generation(cacheCtx, userID)
	if err != nil {
		p.log.Warn("skip embedding cache write: cannot read the cache generation",
			slog.String("request_id", httpx.RequestIDFrom(ctx)), slog.String("error", err.Error()))
		return 0, false
	}
	return generation, true
}

// cacheEmbeddings 把这次嵌入的向量写进缓存，供换机、重建与切换模型时复用。
// 只在客户端带 X-Zhixin-Embedding-Cache: 1 时写；写入失败不影响已经返回的嵌入
// 结果，派生的那部分数据下一次索引刷新会重新算一遍。
//
// generation 是这次请求开始、调用来源之前读到的账号代次，generationOK 为 false
// 表示没读（不该写）或读失败。写入时由缓存实现比较代次，对不上就丢弃。
//
// 服务端自己按原文计算哈希，客户端不能指定某个哈希对应哪个向量，因此缓存里
// 的键与客户端查找时算出的键是同一个口径。
func (p *Proxy) cacheEmbeddings(r *http.Request, userID, model string, inputs []string, vectors []json.RawMessage, generation int64, generationOK bool) {
	if p.cache == nil || r.Header.Get(embeddingCacheHeader) != "1" {
		return
	}
	// 读不到代次时没有可比较的依据，宁可这次不写：没有代次就无从判断中间是否
	// 清空过。读取处的日志已经记过原因。
	if !generationOK {
		return
	}
	if len(vectors) != len(inputs) {
		p.log.Warn("skip embedding cache write: vector count does not match input count",
			slog.String("request_id", httpx.RequestIDFrom(r.Context())))
		return
	}
	items := make([]CachedVector, 0, len(inputs))
	skipped := 0
	for i, text := range inputs {
		vec, err := parseEmbedding(vectors[i])
		if err != nil || len(vec) == 0 {
			skipped++
			continue
		}
		items = append(items, CachedVector{Hash: textHash(text), Dim: len(vec), Vector: encodeVector(vec)})
	}
	if skipped > 0 {
		p.log.Warn("skip embedding cache write for some vectors that could not be decoded",
			slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.Int("skipped", skipped))
	}
	if len(items) == 0 {
		return
	}
	// 写入只按代次判断清除有没有在读取与写入之间发生过：代次对不上时丢弃这次
	// 写入，清除之后不会又冒出旧向量（ADR-0037）。清除进行期间新发起的嵌入请求
	// 由进程内的 cloudOperations 挡在处理器之前，走不到这里。
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), embeddingCacheTimeout)
	defer cancel()
	if err := p.cache.Put(ctx, userID, model, items, generation); err != nil {
		p.log.Error("write embedding cache",
			slog.String("request_id", httpx.RequestIDFrom(r.Context())), slog.String("error", err.Error()))
	}
}

// SetEmbeddingCache 注入向量缓存实现，由 server 装配时调用。没有注入时查找返回
// 空结果、嵌入不写缓存，旧客户端与其他装配方式的行为不变。
func (p *Proxy) SetEmbeddingCache(cache EmbeddingCache) {
	p.cache = cache
	if setter, ok := cache.(cacheLimits); ok {
		setter.SetEmbeddingCacheLimit(p.cfg.EmbeddingCacheBytes)
	}
}

// DeleteEmbeddingCache 删除一个对外模型的全部缓存行；管理后台删除模型或改变
// 维度时调用。返回错误时调用方回 500，模型与缓存都还在，可以重试。
func (p *Proxy) DeleteEmbeddingCache(ctx context.Context, model string) error {
	if p.cache == nil {
		return nil
	}
	return p.cache.DeleteModel(ctx, model)
}
