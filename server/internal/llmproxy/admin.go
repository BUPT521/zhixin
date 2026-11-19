package llmproxy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// Admin 是管理后台的模型来源与路由接口。鉴权由 internal/admin 的中间件完成，
// 这里只做校验、保存与刷新路由快照。key 只进不出：保存时加密，列表只给末四位。
type Admin struct {
	proxy   *Proxy
	catalog Catalog
	box     *secretbox.Box
	maxJSON int64
	now     func() time.Time
}

// NewAdmin 组装管理接口。box 为 nil 时不能保存带 key 的来源。
func NewAdmin(proxy *Proxy, catalog Catalog, box *secretbox.Box, maxJSON int64) *Admin {
	return &Admin{proxy: proxy, catalog: catalog, box: box, maxJSON: maxJSON, now: time.Now}
}

func (a *Admin) router() *Router { return a.proxy.router }

// fresh 先从存储重新读一遍，让列表反映直接改库或其他实例的修改。
func (a *Admin) fresh(w http.ResponseWriter, r *http.Request) (*snapshot, bool) {
	if err := a.router().Reload(r.Context()); err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return nil, false
	}
	return a.router().current(), true
}

func (a *Admin) providerView(p *liveProvider) api.AdminProvider {
	h := a.router().health.view(p.ID)
	state := api.AdminProviderHealthStateOk
	switch {
	case p.KeyBroken:
		state = api.AdminProviderHealthStateKeyError
	case a.router().health.cooling(p.ID):
		state = api.AdminProviderHealthStateCooling
	}
	v := api.AdminProvider{
		Id: p.ID, Name: p.Name, BaseUrl: p.BaseURL, Enabled: p.Enabled,
		HasKey: p.APIKeySealed != "" || p.APIKey != "", Note: p.Note,
		Source: api.AdminProviderSource(p.Source),
		Health: api.AdminProviderHealth{State: state, ConsecutiveFailures: h.failures},
	}
	if p.KeyHint != "" {
		hint := p.KeyHint
		v.KeyHint = &hint
	}
	if !p.UpdatedAt.IsZero() {
		t := p.UpdatedAt
		v.UpdatedAt = &t
	}
	if h.lastError != "" {
		msg, at := h.lastError, h.lastErrorAt
		v.Health.LastError, v.Health.LastErrorAt = &msg, &at
	}
	if !h.lastSuccessAt.IsZero() {
		at := h.lastSuccessAt
		v.Health.LastSuccessAt = &at
	}
	if !h.coolingUntil.IsZero() && a.router().health.cooling(p.ID) {
		at := h.coolingUntil
		v.Health.CoolingUntil = &at
	}
	return v
}

func (a *Admin) modelView(snap *snapshot, m *liveModel) api.AdminModel {
	v := api.AdminModel{
		Name: m.Name, Kind: api.ModelKind(m.Kind), Enabled: m.Enabled, Available: m.usable(), Note: m.Note,
		Source: api.AdminModelSource(m.Source), Routes: make([]api.AdminRoute, 0, len(m.Routes)),
	}
	if m.Dimensions > 0 {
		d := m.Dimensions
		v.Dimensions = &d
	}
	if !m.UpdatedAt.IsZero() {
		t := m.UpdatedAt
		v.UpdatedAt = &t
	}
	for _, rt := range m.Routes {
		provider := snap.byID[rt.ProviderID]
		state := api.AdminRouteStateReady
		switch {
		case !m.Enabled || !rt.Enabled:
			state = api.AdminRouteStateDisabled
		case provider == nil:
			state = api.AdminRouteStateProviderMissing
		case !provider.Enabled:
			state = api.AdminRouteStateProviderDisabled
		case provider.KeyBroken:
			state = api.AdminRouteStateKeyError
		case a.router().health.cooling(rt.ProviderID):
			state = api.AdminRouteStateCooling
		}
		v.Routes = append(v.Routes, api.AdminRoute{
			ProviderId: rt.ProviderID, UpstreamModel: rt.UpstreamModel,
			Priority: rt.Priority, Weight: rt.Weight, MaxBatch: rt.MaxBatch, Enabled: rt.Enabled, State: state,
		})
	}
	return v
}

func (a *Admin) ListProviders(w http.ResponseWriter, r *http.Request) {
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	out := api.AdminProviderList{Data: make([]api.AdminProvider, 0, len(snap.providers))}
	for _, p := range snap.providers {
		out.Data = append(out.Data, a.providerView(p))
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// validBaseURL 要求绝对的 http 或 https 地址，不带用户名、查询串与片段；
// 返回去掉末尾斜杠的形式，请求时直接拼接 /chat/completions。
func validBaseURL(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", false
	}
	return strings.TrimRight(u.String(), "/"), true
}

func (a *Admin) PutProvider(w http.ResponseWriter, r *http.Request, id string) {
	if id == EnvProviderID {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "env is reserved for the provider from environment variables")
		return
	}
	if !ValidProviderID(id) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "id: lowercase letters, digits, - and _, at most 32")
		return
	}
	var in api.AdminProviderInput
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	base, ok := validBaseURL(in.BaseUrl)
	if !ok {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "base_url: want an absolute http or https URL without query")
		return
	}
	if a.proxy.cfg.RestrictProviders {
		u, _ := url.Parse(base)
		addr, ipErr := netip.ParseAddr(u.Hostname())
		if u.Scheme != "https" || (ipErr == nil && !publicProviderIP(addr)) {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, errProviderAddress.Error())
			return
		}
	}
	rec, err := a.catalog.Provider(r.Context(), id)
	if err != nil && !errors.Is(err, ErrNotFound) {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	if rec.APIKeySealed != "" && in.ApiKey == nil && rec.BaseURL != base {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "base_url changed: enter api_key again")
		return
	}
	rec.ID = id
	rec.BaseURL = base
	rec.Name = strings.TrimSpace(deref(in.Name, ""))
	if rec.Name == "" {
		rec.Name = id
	}
	rec.Note = strings.TrimSpace(deref(in.Note, ""))
	if utf8.RuneCountInString(rec.Name) > 64 || utf8.RuneCountInString(rec.Note) > 200 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "name or note is too long")
		return
	}
	rec.Enabled = deref(in.Enabled, true)
	if in.ApiKey != nil {
		key := strings.TrimSpace(*in.ApiKey)
		if strings.ContainsAny(key, " \t\r\n") {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "api_key must not contain whitespace")
			return
		}
		if key != "" && a.box == nil {
			httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "ZHIXIN_SECRET_KEY is not set; keys cannot be stored")
			return
		}
		rec.APIKeySealed, rec.KeyHint = "", ""
		if key != "" {
			sealed, err := a.box.Seal(key, KeyAAD(id, base))
			if err != nil {
				httpx.WriteInternal(w, r, a.proxy.log, err)
				return
			}
			rec.APIKeySealed, rec.KeyHint = sealed, keyHint(key)
		}
	}
	rec.UpdatedAt = a.now().UTC()
	if err := a.catalog.PutProvider(r.Context(), rec); err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	saved, found := snap.byID[id]
	if !found {
		httpx.WriteInternal(w, r, a.proxy.log, errors.New("saved provider missing from the reloaded routes"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, a.providerView(saved))
}

func (a *Admin) DeleteProvider(w http.ResponseWriter, r *http.Request, id string) {
	if id == EnvProviderID {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "the env provider is configured by environment variables")
		return
	}
	err := a.catalog.DeleteProvider(r.Context(), id)
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	case errors.Is(err, ErrProviderInUse):
		models, lerr := a.catalog.Models(r.Context())
		if lerr != nil {
			httpx.WriteInternal(w, r, a.proxy.log, lerr)
			return
		}
		httpx.WriteProblemExtra(w, r, http.StatusConflict, httpx.CodeConflict,
			"remove the routes that use this provider first", map[string]any{"models": ModelsUsingProvider(models, id)})
		return
	case err != nil:
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	if _, ok := a.fresh(w, r); !ok {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// TestProvider 用来源自己的 key 请求一次 GET /models，检查地址与 key。
func (a *Admin) TestProvider(w http.ResponseWriter, r *http.Request, id string) {
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	p, found := snap.byID[id]
	if !found {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	out := api.AdminProbe{ProviderId: &p.ID}
	if p.KeyBroken {
		msg := "保存的 key 无法用当前的 ZHIXIN_SECRET_KEY 解密，请重新填写 key"
		out.Error = &msg
		httpx.WriteJSON(w, http.StatusOK, out)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.BaseURL+"/models", nil)
	if err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	if p.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+p.APIKey)
	}
	resp, err := a.proxy.sendToProvider(req, p)
	out.LatencyMs = time.Since(start).Milliseconds()
	if err != nil {
		msg := "无法连接模型来源"
		out.Error = &msg
		httpx.WriteJSON(w, http.StatusOK, out)
		return
	}
	defer resp.Body.Close()
	status := resp.StatusCode
	out.Status = &status
	if status >= 300 {
		msg := fmt.Sprintf("HTTP %d", status)
		out.Error = &msg
		httpx.WriteJSON(w, http.StatusOK, out)
		return
	}
	body, err := readResponse(resp.Body, 4<<20)
	var list struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err != nil || json.Unmarshal(body, &list) != nil || list.Data == nil {
		msg := "来源未返回有效的模型列表"
		out.Error = &msg
		httpx.WriteJSON(w, http.StatusOK, out)
		return
	}
	names := make([]string, 0, len(list.Data))
	for _, d := range list.Data {
		if d.ID != "" {
			names = append(names, d.ID)
		}
	}
	sort.Strings(names)
	if len(names) > 500 {
		names = names[:500]
	}
	out.Ok = true
	out.Models = &names
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (a *Admin) ListModels(w http.ResponseWriter, r *http.Request) {
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	out := api.AdminModelList{Data: make([]api.AdminModel, 0, len(snap.models))}
	for _, m := range snap.models {
		out.Data = append(out.Data, a.modelView(snap, m))
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (a *Admin) PutModel(w http.ResponseWriter, r *http.Request, name string) {
	if !ValidModelName(name) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "name: letters, digits, . _ : -, at most 64, no slash")
		return
	}
	var in api.AdminModelInput
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	rec := ModelRecord{
		Name: name, Kind: Kind(in.Kind), Enabled: deref(in.Enabled, true),
		Note: strings.TrimSpace(deref(in.Note, "")), UpdatedAt: a.now().UTC(),
	}
	bad := func(detail string) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, detail)
	}
	switch rec.Kind {
	case KindChat:
		if in.Dimensions != nil {
			bad("dimensions only applies to embedding models")
			return
		}
	case KindEmbedding:
		if in.Dimensions != nil {
			if *in.Dimensions < 1 || *in.Dimensions > 8192 {
				bad("dimensions: 1 to 8192")
				return
			}
			rec.Dimensions = *in.Dimensions
		}
	default:
		bad("kind: chat or embedding")
		return
	}
	if utf8.RuneCountInString(rec.Note) > 200 {
		bad("note is too long")
		return
	}
	if len(in.Routes) == 0 || len(in.Routes) > 16 {
		bad("routes: 1 to 16")
		return
	}
	seen := map[[2]string]bool{}
	for _, ri := range in.Routes {
		rt := Route{
			ProviderID:    strings.TrimSpace(ri.ProviderId),
			UpstreamModel: strings.TrimSpace(ri.UpstreamModel),
			Priority:      deref(ri.Priority, 0),
			Weight:        deref(ri.Weight, 1),
			MaxBatch:      deref(ri.MaxBatch, 0),
			Enabled:       deref(ri.Enabled, true),
		}
		switch {
		case rt.ProviderID == EnvProviderID:
			bad("routes: the env provider only serves ZHIXIN_LLM_MODELS; add the source in the admin page instead")
			return
		case rt.UpstreamModel == "" || utf8.RuneCountInString(rt.UpstreamModel) > 128:
			bad("routes: upstream_model is required, at most 128 characters")
			return
		case rt.Priority < 0 || rt.Priority > 100:
			bad("routes: priority 0 to 100")
			return
		case rt.Weight < 1 || rt.Weight > 1000:
			bad("routes: weight 1 to 1000")
			return
		case rt.MaxBatch < 0 || rt.MaxBatch > 2048:
			bad("routes: max_batch 0 to 2048")
			return
		case seen[[2]string{rt.ProviderID, rt.UpstreamModel}]:
			bad("routes: duplicate provider_id and upstream_model")
			return
		}
		seen[[2]string{rt.ProviderID, rt.UpstreamModel}] = true
		rec.Routes = append(rec.Routes, rt)
	}
	// 改维度或改用途之后旧向量不再可用：先删这个模型的缓存，再保存。缓存删除
	// 失败时模型还没改，重试仍然会走清理；同名模型必须是同一个向量空间，换部署
	// 要换对外模型名，这条约束见 ADR-0029（ADR-0030 第 7 条）。
	if old, ok := a.router().current().model(name); ok && (old.Kind != rec.Kind || old.Dimensions != rec.Dimensions) {
		if err := a.proxy.DeleteEmbeddingCache(r.Context(), name); err != nil {
			httpx.WriteInternal(w, r, a.proxy.log, err)
			return
		}
	}
	if err := a.catalog.PutModel(r.Context(), rec); err != nil {
		if errors.Is(err, ErrUnknownProvider) {
			bad("routes: provider_id does not exist")
			return
		}
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	saved, found := snap.model(name)
	if !found {
		httpx.WriteInternal(w, r, a.proxy.log, errors.New("saved model missing from the reloaded routes"))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, a.modelView(snap, saved))
}

func (a *Admin) DeleteModel(w http.ResponseWriter, r *http.Request, name string) {
	// 先确认这是管理后台的模型，环境变量来源的模型只读，不能连带删掉缓存。
	models, err := a.catalog.Models(r.Context())
	if err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	found := false
	for _, m := range models {
		if m.Name == name {
			found = true
			break
		}
	}
	if !found {
		if m, ok := a.router().current().model(name); ok && m.Source == sourceEnv {
			httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "this model comes from ZHIXIN_LLM_MODELS or ZHIXIN_LLM_EMBEDDING_MODELS")
			return
		}
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	// 先删缓存再删模型：缓存删除失败时模型还在，重试删除仍然可用。缓存是派生
	// 数据，多删一次只是让客户端重新嵌入（ADR-0030 第 7 条）。
	if err := a.proxy.DeleteEmbeddingCache(r.Context(), name); err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	if err := a.catalog.DeleteModel(r.Context(), name); err != nil {
		if errors.Is(err, ErrNotFound) {
			// 另一个管理请求已经先删掉了：缓存也已清空，按删除成功处理没有意义，
			// 回 404 让调用方知道模型不在。
			httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
			return
		}
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	if _, ok := a.fresh(w, r); !ok {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// TestModel 按路由发一次最小请求。不计入任何账号的额度，结果会更新来源的
// 健康状态，与真实请求同一口径。
func (a *Admin) TestModel(w http.ResponseWriter, r *http.Request, name string) {
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	m, found := snap.model(name)
	if !found {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	cands := a.router().candidates(m, a.proxy.cfg.MaxAttempts)
	out := api.AdminProbe{}
	fail := func(msg string) {
		out.Error = &msg
		httpx.WriteJSON(w, http.StatusOK, out)
	}
	if len(cands) == 0 {
		fail("没有可用的路由：检查路由与来源是否启用、key 是否能解密")
		return
	}
	start := time.Now()
	if m.Kind == KindEmbedding {
		input, _ := json.Marshal([]string{"知新：把学过的内容找回来"})
		fields := map[string]json.RawMessage{"input": input}
		res := a.proxy.embed(ctx, m, cands, fields, []string{"知新：把学过的内容找回来"}, nil)
		out.LatencyMs = time.Since(start).Milliseconds()
		if res.route.Provider != nil {
			out.ProviderId, out.UpstreamModel = &res.route.Provider.ID, &res.route.UpstreamModel
		}
		switch {
		case res.passthrough != nil:
			status := res.passthrough.status
			out.Status = &status
			fail(fmt.Sprintf("HTTP %d", status))
		case res.err != nil:
			fail(res.failure())
		default:
			status := http.StatusOK
			out.Status, out.Ok = &status, true
			if res.dimensions > 0 {
				d := res.dimensions
				out.Dimensions = &d
			}
			httpx.WriteJSON(w, http.StatusOK, out)
		}
		return
	}
	fields := map[string]json.RawMessage{
		"messages":   json.RawMessage(`[{"role":"user","content":"ping"}]`),
		"max_tokens": json.RawMessage(`1`),
		"stream":     json.RawMessage(`false`),
	}
	reply, err := a.proxy.dispatch(ctx, cands, fields, false, 0, nil)
	out.LatencyMs = time.Since(start).Milliseconds()
	if reply.route.Provider != nil {
		out.ProviderId, out.UpstreamModel = &reply.route.ProviderID, &reply.route.UpstreamModel
	}
	if err != nil {
		fail("没有来源返回可用的聊天响应")
		return
	}
	out.Status = &reply.status
	if reply.status < 200 || reply.status >= 300 {
		fail(fmt.Sprintf("HTTP %d", reply.status))
		return
	}
	out.Ok = true
	httpx.WriteJSON(w, http.StatusOK, out)
}

func deref[T any](p *T, def T) T {
	if p == nil {
		return def
	}
	return *p
}
