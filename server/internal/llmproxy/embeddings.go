package llmproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

const (
	// embedConcurrency 是一次请求拆成多批时同时发给来源的批数。
	embedConcurrency = 4
	// maxEmbedResponse 限制单批响应的大小：256 条 4096 维的浮点数组约 20 MB。
	maxEmbedResponse = 128 << 20
)

// errBadUpstream 表示来源返回了 200，但内容不能用：条数、序号或维度不对。
var errBadUpstream = errors.New("upstream returned an unusable embedding response")

var embeddingFields = map[string]bool{"model": true, "input": true, "dimensions": true, "encoding_format": true}

// Embeddings 代理 OpenAI Embeddings。一次请求可以带多条输入；路由配置了
// max_batch 时拆成几批并发发给同一个来源，再按原顺序合并。一批失败时整次请求
// 换下一个来源重做，所以同一次请求的向量总是来自同一个来源。
func (p *Proxy) Embeddings(w http.ResponseWriter, r *http.Request) {
	userID := auth.MustPrincipal(r.Context()).UserID
	if !p.beginRequest(w, r, userID) {
		return
	}
	defer p.releaseConcurrency(userID)
	fields, ok := p.readBody(w, r)
	if !ok || !allowFields(w, r, fields, embeddingFields) {
		return
	}
	inputs, err := parseInputs(fields["input"])
	if err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}
	if len(inputs) > p.cfg.EmbeddingMaxInputs {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			fmt.Sprintf("at most %d inputs per request", p.cfg.EmbeddingMaxInputs),
			map[string]any{"max_inputs": p.cfg.EmbeddingMaxInputs})
		return
	}
	m := p.findModel(w, r, fields, KindEmbedding)
	if m == nil {
		return
	}
	// 客户端要求的维度与配置不一致时直接拒绝：否则来源按客户端的要求返回，
	// 服务端的维度核对会把它当成来源故障，一个账号就能让来源对所有人冷却。
	if raw, set := fields["dimensions"]; set && m.Dimensions > 0 {
		var want int
		if json.Unmarshal(raw, &want) != nil || want != m.Dimensions {
			httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
				"dimensions does not match the configured model", map[string]any{"dimensions": m.Dimensions})
			return
		}
	}

	day := p.day()

	ctx := r.Context()
	if p.cfg.StreamTotalTimeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, p.cfg.StreamTotalTimeout)
		defer cancel()
	}
	res := p.embed(ctx, m, p.router.candidates(m, p.cfg.MaxAttempts), fields, inputs, p.budget(r, userID, day, KindEmbedding))
	var budgetError quotaReservationError
	switch {
	case errors.Is(res.err, ErrQuotaExceeded):
		p.writeQuotaExceeded(w, r, userID, day, KindEmbedding)
	case errors.As(res.err, &budgetError):
		httpx.WriteInternal(w, r, p.log, res.err)
	case res.passthrough != nil:
		writeUpstreamStatus(w, r, res.passthrough.status)
	case res.err != nil:
		if r.Context().Err() != nil {
			return
		}
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed, "could not get embeddings from any model source")
	default:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(res.body)
		// 响应已经写出，再把向量写进缓存；客户端带缓存请求头时才有这一步。
		p.cacheEmbeddings(r, userID, m.Name, inputs, res.vectors)
	}
}

// parseInputs 接受字符串或字符串数组；token 数组之类的形式不转发，因为服务端
// 要按条拆批，也要在缺少 usage 时按输入字节估算用量。
func parseInputs(raw json.RawMessage) ([]string, error) {
	if len(raw) == 0 {
		return nil, errors.New("input is required")
	}
	var one string
	if err := json.Unmarshal(raw, &one); err == nil {
		if one == "" {
			return nil, errors.New("input must not be empty")
		}
		return []string{one}, nil
	}
	var many []string
	if err := json.Unmarshal(raw, &many); err != nil {
		return nil, errors.New("input must be a string or an array of strings")
	}
	if len(many) == 0 {
		return nil, errors.New("input must not be empty")
	}
	for _, s := range many {
		if s == "" {
			return nil, errors.New("input must not contain empty strings")
		}
	}
	return many, nil
}

type rawResponse struct {
	status int
	body   []byte
}

type embedResult struct {
	body        []byte
	tokens      int64
	dimensions  int
	route       liveRoute
	passthrough *rawResponse
	err         error
	// vectors 是按输入顺序合并好的向量，用来写入嵌入缓存；只有成功时才有值。
	vectors []json.RawMessage
}

// embed 依次尝试候选路由，返回合并好的响应、需要原样转交的提供方错误，或者
// 全部失败时的错误。
func (p *Proxy) embed(ctx context.Context, m *liveModel, cands []liveRoute, fields map[string]json.RawMessage, inputs []string, reserve attemptBudget) embedResult {
	last := embedResult{err: errors.New("no usable route")}
	for _, rt := range cands {
		settle := func(int64) {}
		if reserve != nil {
			var err error
			settle, err = reserve(embeddingEstimate(inputs))
			if err != nil {
				return embedResult{err: err}
			}
		}
		res, retry := p.embedOnce(ctx, m, rt, fields, inputs)
		settle(res.tokens)
		if ctx.Err() != nil {
			return embedResult{err: ctx.Err()}
		}
		if !retry {
			if res.err == nil && res.passthrough == nil {
				p.router.health.succeed(rt.Provider.ID)
			}
			return res
		}
		p.router.health.fail(rt.Provider.ID, res.failure())
		last = res
	}
	return last
}

func (res embedResult) failure() string {
	switch {
	case res.passthrough != nil:
		return fmt.Sprintf("HTTP %d", res.passthrough.status)
	case errors.Is(res.err, errBadUpstream):
		return "嵌入响应不可用：" + res.err.Error()
	case res.err != nil:
		return "无法读取模型来源的响应"
	}
	return ""
}

type chunkOut struct {
	resp   rawResponse
	err    error
	tokens int64
}

func embeddingEstimate(inputs []string) int64 {
	var size int64
	for _, s := range inputs {
		size += int64(len(s))
	}
	return size
}

// embedOnce 用一条路由完成整次请求。retry 为真表示应该换下一个来源。
func (p *Proxy) embedOnce(ctx context.Context, m *liveModel, rt liveRoute, fields map[string]json.RawMessage, inputs []string) (embedResult, bool) {
	batch := rt.MaxBatch
	if batch <= 0 || batch > len(inputs) {
		batch = len(inputs)
	}
	var chunks [][]string
	for start := 0; start < len(inputs); start += batch {
		chunks = append(chunks, inputs[start:min(start+batch, len(inputs))])
	}

	// 一批失败时取消其余几批：整次请求反正要换来源重做，不必等它们跑完。
	bctx, cancel := context.WithCancel(ctx)
	defer cancel()
	outs := make([]chunkOut, len(chunks))
	sem := make(chan struct{}, embedConcurrency)
	var wg sync.WaitGroup
	var sizeMu sync.Mutex
	var totalBytes int64
	for i, chunk := range chunks {
		wg.Add(1)
		go func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-bctx.Done():
				outs[i] = chunkOut{err: bctx.Err()}
				return
			}
			defer func() { <-sem }()
			out := p.embedChunk(bctx, rt, fields, chunk)
			if out.err == nil {
				sizeMu.Lock()
				totalBytes += int64(len(out.resp.body))
				if p.cfg.MaxResponseBytes > 0 && totalBytes > p.cfg.MaxResponseBytes {
					out.err = errResponseTooLarge
					out.resp = rawResponse{}
				}
				sizeMu.Unlock()
			}
			outs[i] = out
			if out.err != nil || out.resp.status >= 300 {
				cancel()
			}
		}()
	}
	wg.Wait()
	var tokens int64
	for _, o := range outs {
		tokens += o.tokens
	}

	// 先找真正的失败：被取消的批次只是受了别的批次连累。
	for _, o := range outs {
		if o.err != nil && !errors.Is(o.err, context.Canceled) {
			return embedResult{err: o.err, route: rt, tokens: tokens}, true
		}
	}
	for _, o := range outs {
		if o.err == nil && retryable(o.resp.status) {
			pt := o.resp
			return embedResult{passthrough: &pt, route: rt, tokens: tokens}, true
		}
	}
	for _, o := range outs {
		if o.err == nil && o.resp.status >= 300 {
			pt := o.resp
			return embedResult{passthrough: &pt, route: rt, tokens: tokens}, false
		}
	}
	for _, o := range outs {
		if o.err != nil {
			return embedResult{err: o.err, route: rt, tokens: tokens}, true
		}
	}

	var merged []json.RawMessage
	dims := 0
	for i, o := range outs {
		vecs, err := parseEmbedChunk(o.resp.body, len(chunks[i]), m.Dimensions)
		if err != nil {
			return embedResult{err: err, route: rt, tokens: tokens}, true
		}
		merged = append(merged, vecs...)
		if dims == 0 && len(vecs) > 0 {
			dims = arrayLen(vecs[0])
		}
	}
	body := renderEmbeddings(m.Name, merged, tokens)
	if p.cfg.MaxResponseBytes > 0 && int64(len(body)) > p.cfg.MaxResponseBytes {
		return embedResult{err: errResponseTooLarge, route: rt, tokens: tokens}, true
	}
	return embedResult{body: body, tokens: tokens, dimensions: dims, route: rt, vectors: merged}, false
}

func (p *Proxy) embedChunk(ctx context.Context, rt liveRoute, fields map[string]json.RawMessage, chunk []string) chunkOut {
	in, err := json.Marshal(chunk)
	if err != nil {
		return chunkOut{err: err}
	}
	f := make(map[string]json.RawMessage, len(fields))
	for k, v := range fields {
		f[k] = v
	}
	f["input"] = in
	body, err := withModel(f, rt.UpstreamModel)
	if err != nil {
		return chunkOut{err: err}
	}
	if err := ctx.Err(); err != nil {
		return chunkOut{err: err}
	}
	estimate := embeddingEstimate(chunk)
	resp, err := p.attempt(ctx, rt.Provider, "/embeddings", body, true)
	if err != nil {
		return chunkOut{err: err, tokens: estimate}
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		used := int64(0)
		if rejectedUsage(resp.StatusCode) < 0 {
			used = estimate
		}
		return chunkOut{resp: rawResponse{status: resp.StatusCode}, tokens: used}
	}
	limit := int64(maxEmbedResponse)
	if p.cfg.MaxResponseBytes > 0 {
		limit = min(limit, p.cfg.MaxResponseBytes)
	}
	b, err := readResponse(resp.Body, limit)
	if err != nil {
		return chunkOut{err: err, tokens: estimate}
	}
	used := usageTokens(b, KindEmbedding)
	if used <= 0 {
		used = estimate
	}
	return chunkOut{resp: rawResponse{status: resp.StatusCode, body: b}, tokens: used}
}

// parseEmbedChunk 取出一批的向量并按 index 排好。来源省略全部 index 或者全部
// 写成 0 时按出现顺序；其余情况 index 必须正好是 0 到 n-1 各一次，否则当作
// 来源返回的内容不可用，不能猜顺序。dims 大于 0 时核对每个浮点数组的长度。
func parseEmbedChunk(body []byte, want, dims int) ([]json.RawMessage, error) {
	var env struct {
		Data []struct {
			Index     *int            `json:"index"`
			Embedding json.RawMessage `json:"embedding"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("%w: not JSON", errBadUpstream)
	}
	if len(env.Data) != want {
		return nil, fmt.Errorf("%w: got %d vectors for %d inputs", errBadUpstream, len(env.Data), want)
	}
	out := make([]json.RawMessage, want)
	positional := true
	for _, d := range env.Data {
		if d.Index != nil && *d.Index != 0 {
			positional = false
			break
		}
	}
	if positional {
		for i, d := range env.Data {
			out[i] = d.Embedding
		}
	} else {
		for _, d := range env.Data {
			if d.Index == nil || *d.Index < 0 || *d.Index >= want || out[*d.Index] != nil {
				return nil, fmt.Errorf("%w: index values are not 0..%d", errBadUpstream, want-1)
			}
			out[*d.Index] = d.Embedding
		}
	}
	for _, v := range out {
		if len(v) == 0 || bytes.Equal(v, []byte("null")) {
			return nil, fmt.Errorf("%w: missing embedding", errBadUpstream)
		}
		if dims > 0 {
			if n := arrayLen(v); n >= 0 && n != dims {
				return nil, fmt.Errorf("%w: got %d dimensions, configured %d", errBadUpstream, n, dims)
			}
		}
	}
	return out, nil
}

// arrayLen 数一个浮点数组的元素个数；不是数组（例如 base64 字符串）时返回 -1。
// 数组里只有数字，逗号数加一就是长度，不需要逐个解析浮点数。
func arrayLen(raw json.RawMessage) int {
	t := bytes.TrimSpace(raw)
	if len(t) < 2 || t[0] != '[' {
		return -1
	}
	if len(bytes.TrimSpace(t[1:len(t)-1])) == 0 {
		return 0
	}
	return bytes.Count(t, []byte(",")) + 1
}

func renderEmbeddings(model string, vecs []json.RawMessage, tokens int64) []byte {
	var b bytes.Buffer
	b.WriteString(`{"object":"list","data":[`)
	for i, v := range vecs {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"object":"embedding","index":`)
		b.WriteString(strconv.Itoa(i))
		b.WriteString(`,"embedding":`)
		b.Write(v)
		b.WriteByte('}')
	}
	name, _ := json.Marshal(model)
	b.WriteString(`],"model":`)
	b.Write(name)
	fmt.Fprintf(&b, `,"usage":{"prompt_tokens":%d,"total_tokens":%d}}`, tokens, tokens)
	return b.Bytes()
}
