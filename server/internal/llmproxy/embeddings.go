package llmproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/api"
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
func (p *Proxy) Embeddings(w http.ResponseWriter, r *http.Request, params api.PostV1LlmEmbeddingsParams) {
	userID := auth.MustPrincipal(r.Context()).UserID
	background := backgroundWorkload(params.XZhixinWorkload)
	done, ok := p.beginRequest(w, r, userID, background)
	if !ok {
		return
	}
	defer done()
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
	// 服务端的维度核对会把它当成路由故障，一个账号就能让这条路由对所有人冷却。
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
	// 缓存代次必须在调用来源之前读：清除可能发生在嵌入进行中，那时请求已经
	// 拿到旧代次，写回时对不上就丢弃这次写入（ADR-0037）。
	generation, generationOK := p.embeddingCacheGeneration(ctx, r, userID)
	plan := attemptPlan{
		model: m, candidates: p.router.candidates(m, "", capabilities{}), reserve: p.budget(r, userID, day, m),
		background: background,
	}
	res := p.embed(ctx, &plan, fields, inputs)
	var budgetError quotaReservationError
	switch {
	case errors.Is(res.err, ErrQuotaExceeded):
		p.writeQuotaExceeded(w, r, userID, day, KindEmbedding)
	case errors.Is(res.err, errInstanceBusy):
		httpx.TooMany(w, r, 1)
	case errors.As(res.err, &budgetError):
		httpx.WriteInternal(w, r, p.log, res.err)
	case res.passthrough != nil:
		writeUpstreamStatus(w, r, res.passthrough.status, res.passthrough.retryAfter)
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
		p.cacheEmbeddings(r, userID, m.Name, inputs, res.vectors, generation, generationOK)
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
	status     int
	body       []byte
	retryAfter string
}

type embedResult struct {
	body        []byte
	usage       attemptResult
	dimensions  int
	route       liveRoute
	passthrough *rawResponse
	err         error
	status      int
	reached     bool
	// vectors 是按输入顺序合并好的向量，用来写入嵌入缓存；只有成功时才有值。
	vectors []json.RawMessage
}

// embed 依次尝试候选路由，返回合并好的响应、需要原样转交的提供方错误，或者
// 全部失败时的错误。
func (p *Proxy) embed(ctx context.Context, plan *attemptPlan, fields map[string]json.RawMessage, inputs []string) embedResult {
	// 一次嵌入请求的响应整段留在内存里：各批正文合起来不超过一个响应上限，合并后
	// 的正文再有同样大小的一份。先从实例预算里预留，占不到时按实例繁忙结束；后台
	// 批次只能占用没有留给前台的那一份。
	release, reserved := p.mem.reserveWorkload(p.embedBytes(), plan.background)
	if !reserved {
		return embedResult{err: errInstanceBusy}
	}
	defer release()
	last := embedResult{err: errors.New("no usable route")}
	estimate := embeddingEstimate(inputs)
	for _, rt := range plan.candidates {
		if !p.attemptsRemain(plan) {
			break
		}
		attempt, started, err := p.beginAttempt(ctx, plan, rt, Usage{Input: estimate})
		if err != nil {
			return embedResult{err: err}
		}
		if !started {
			continue
		}
		concurrency := embedConcurrency
		if attempt.lease.source.probe || attempt.lease.route.probe {
			concurrency = 1
		}
		res, retry := p.embedOnce(ctx, plan.model, rt, fields, inputs, concurrency)
		outcome := healthOutcome{sourceReached: res.reached}
		switch {
		case ctx.Err() != nil:
			outcome = healthOutcome{reason: "请求已取消或超时"}
		case res.passthrough != nil:
			outcome = httpFailure(res.status, res.passthrough.retryAfter)
		case res.err != nil:
			var connection sourceConnectionError
			if errors.As(res.err, &connection) {
				outcome = requestFailure(ctx, res.err)
			} else {
				outcome.scope, outcome.reason = routeFailure, res.failure()
			}
		}
		p.finishAttempt(plan, attempt, res.usage, res.status, outcome)
		if ctx.Err() != nil {
			res.err = ctx.Err()
			res.passthrough = nil
			return res
		}
		if !retry {
			return res
		}
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
	resp              rawResponse
	err               error
	tokens, estimated int64
}

func embeddingEstimate(inputs []string) int64 {
	var size int64
	for _, s := range inputs {
		size += int64(len(s))
	}
	return size
}

// embedBytes 是一次嵌入请求在实例预算里占用的字节数：各批正文合计不超过一个
// 响应上限，合并后的正文再有一份同样大小的。
func (p *Proxy) embedBytes() int64 {
	if p.cfg.MaxResponseBytes <= 0 {
		return 0
	}
	return 2 * p.cfg.MaxResponseBytes
}

// embedOnce 用一条路由完成整次请求。retry 为真表示应该换下一个来源。
func (p *Proxy) embedOnce(ctx context.Context, m *liveModel, rt liveRoute, fields map[string]json.RawMessage, inputs []string, concurrency int) (embedResult, bool) {
	batch := rt.MaxBatch
	if batch <= 0 || batch > len(inputs) {
		batch = len(inputs)
	}
	var chunks [][]string
	for start := 0; start < len(inputs); start += batch {
		chunks = append(chunks, inputs[start:min(start+batch, len(inputs))])
	}
	// 各批并发读取，响应字节由一次请求共享同一份额度：任何一批都不能把别的批
	// 挤到内存之外，四批同时读满时合计仍不超过一个响应上限（ADR-0036）。
	allowance := newChunkAllowance(p.cfg.MaxResponseBytes)

	// 一批失败时取消其余几批：整次请求反正要换来源重做，不必等它们跑完。
	bctx, cancel := context.WithCancel(ctx)
	defer cancel()
	outs := make([]chunkOut, len(chunks))
	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
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
			out := p.embedChunk(bctx, rt, fields, chunk, allowance)
			outs[i] = out
			if out.err != nil || out.resp.status >= 300 {
				cancel()
			}
		}()
	}
	wg.Wait()
	res := embedResult{route: rt}
	for _, o := range outs {
		res.usage.usage.Input += o.tokens
		res.usage.estimated += o.estimated
		res.reached = res.reached || (o.resp.status != 0 && o.resp.status != http.StatusUnauthorized)
	}
	// Shared credential and connection failures take precedence over individual batch errors.
	for _, o := range outs {
		if o.resp.status == http.StatusUnauthorized {
			res.passthrough, res.status = &o.resp, o.resp.status
			return res, true
		}
	}
	for _, o := range outs {
		var connection sourceConnectionError
		if errors.As(o.err, &connection) && !errors.Is(o.err, context.Canceled) {
			res.err = o.err
			return res, true
		}
	}

	// 先找真正的失败：被取消的批次只是受了别的批次连累。
	for _, o := range outs {
		if o.err != nil && !errors.Is(o.err, context.Canceled) {
			res.err, res.status = o.err, o.resp.status
			return res, true
		}
	}
	for _, o := range outs {
		if o.err == nil && retryable(o.resp.status) {
			res.passthrough, res.status = &o.resp, o.resp.status
			return res, true
		}
	}
	for _, o := range outs {
		if o.err == nil && o.resp.status >= 300 {
			res.passthrough, res.status = &o.resp, o.resp.status
			return res, false
		}
	}
	for _, o := range outs {
		if o.err != nil {
			res.err, res.status = o.err, o.resp.status
			return res, true
		}
	}

	var merged []json.RawMessage
	dims := 0
	for i, o := range outs {
		vecs, err := parseEmbedChunk(o.resp.body, len(chunks[i]), m.Dimensions)
		if err != nil {
			res.err, res.status = err, o.resp.status
			return res, true
		}
		merged = append(merged, vecs...)
		if dims == 0 && len(vecs) > 0 {
			dims = arrayLen(vecs[0])
		}
	}
	res.status = outs[0].resp.status
	body := renderEmbeddings(m.Name, merged, res.usage.usage.Total())
	if p.cfg.MaxResponseBytes > 0 && int64(len(body)) > p.cfg.MaxResponseBytes {
		res.err = errResponseTooLarge
		return res, true
	}
	res.usage.success = true
	res.usage.unknown = res.usage.usage.Total() <= 0
	res.body, res.dimensions, res.vectors = body, dims, merged
	return res, false
}

func (p *Proxy) embedChunk(ctx context.Context, rt liveRoute, fields map[string]json.RawMessage, chunk []string, allowance *chunkAllowance) chunkOut {
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
	resp, err := p.attempt(ctx, rt.Provider, "/embeddings", body, false, p.cfg.HeaderTimeout)
	if err != nil {
		return chunkOut{err: err, tokens: estimate, estimated: estimate}
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		used := int64(0)
		if rejectedUsage(resp.StatusCode) < 0 {
			used = estimate
		}
		return chunkOut{
			resp:   rawResponse{status: resp.StatusCode, retryAfter: resp.Header.Get("Retry-After")},
			tokens: used, estimated: used,
		}
	}
	limit := int64(maxEmbedResponse)
	if p.cfg.MaxResponseBytes > 0 {
		limit = min(limit, p.cfg.MaxResponseBytes)
	}
	b, err := readResponse(allowanceReader{r: resp.Body, a: allowance}, limit)
	if err != nil {
		return chunkOut{resp: rawResponse{status: resp.StatusCode}, err: err, tokens: estimate, estimated: estimate}
	}
	used := parseUsage(b, KindEmbedding).Total()
	if used <= 0 {
		return chunkOut{resp: rawResponse{status: resp.StatusCode, body: b}, tokens: estimate, estimated: estimate}
	}
	return chunkOut{resp: rawResponse{status: resp.StatusCode, body: b}, tokens: used}
}

// chunkAllowance 是一次嵌入请求里各批共享的响应字节额度。批次并发读取，合计不能
// 超过一个请求的响应上限，否则四批各自读满时内存会被放大到四倍（ADR-0036）。
type chunkAllowance struct {
	mu   sync.Mutex
	left int64
}

// newChunkAllowance 按请求的响应上限建一份额度；limit 小于等于 0 表示不限制。
func newChunkAllowance(limit int64) *chunkAllowance {
	if limit <= 0 {
		limit = maxEmbedResponse
	}
	return &chunkAllowance{left: limit}
}

// take 返回这一轮最多允许读取的字节数：额度用完时返回 0，读取方据此按响应过大
// 处理，不必先读进内存再判断合计。
func (a *chunkAllowance) take(n int64) int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.left <= 0 {
		return 0
	}
	if n > a.left {
		n = a.left
	}
	a.left -= n
	return n
}

// allowanceReader 把共享额度接到上游响应体上。读满额度之后再读一次返回
// errResponseTooLarge，读到的字节数因此不会超过整次请求的响应上限。
type allowanceReader struct {
	r io.Reader
	a *chunkAllowance
}

func (r allowanceReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	n := r.a.take(int64(len(p)))
	if n <= 0 {
		// 额度用尽之后再读一次只为确认是否正好读完：来源正好写满上限时这里应当
		// 得到 EOF，多出一个字节才按响应过大处理。
		var probe [1]byte
		read, err := r.r.Read(probe[:])
		if read > 0 {
			return 0, errResponseTooLarge
		}
		return 0, err
	}
	return r.r.Read(p[:n])
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
