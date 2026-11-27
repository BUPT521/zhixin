package llmproxy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/BUPT521/zhixin/server/internal/api"
	sharedderef "github.com/BUPT521/zhixin/server/internal/deref"
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
	health := adminHealthView(a.router().health.view(healthKey{provider: p.ID}))
	if p.KeyBroken {
		health.State = api.AdminHealthStateKeyError
	}
	v := api.AdminProvider{
		Id: p.ID, Name: p.Name, BaseUrl: p.BaseURL, Enabled: p.Enabled,
		HasKey: p.APIKeySealed != "" || p.APIKey != "", Note: p.Note,
		Health: health,
	}
	if p.KeyHint != "" {
		hint := p.KeyHint
		v.KeyHint = &hint
	}
	if !p.UpdatedAt.IsZero() {
		t := p.UpdatedAt
		v.UpdatedAt = &t
	}
	return v
}

func adminHealthView(h healthView) api.AdminHealth {
	state := api.AdminHealthStateOk
	switch h.phase {
	case healthCooling:
		state = api.AdminHealthStateCooling
	case healthProbeReady:
		state = api.AdminHealthStateProbeReady
	case healthProbing:
		state = api.AdminHealthStateProbing
	}
	v := api.AdminHealth{State: state, ConsecutiveFailures: h.failures}
	if h.lastError != "" {
		msg, at := h.lastError, h.lastErrorAt
		v.LastError, v.LastErrorAt = &msg, &at
	}
	if !h.lastSuccessAt.IsZero() {
		at := h.lastSuccessAt
		v.LastSuccessAt = &at
	}
	if h.phase == healthCooling {
		at := h.coolingUntil
		v.CoolingUntil = &at
	}
	return v
}

func (a *Admin) modelView(snap *snapshot, m *liveModel) api.AdminModel {
	v := api.AdminModel{
		Name: m.Name, Kind: api.ModelKind(m.Kind), Enabled: m.Enabled, Note: m.Note,
		Routes: make([]api.AdminRoute, 0, len(m.Routes)),
	}
	if m.Dimensions > 0 {
		d := m.Dimensions
		v.Dimensions = &d
	}
	if !m.UpdatedAt.IsZero() {
		t := m.UpdatedAt
		v.UpdatedAt = &t
	}
	states := a.router().health.modelViews(m)
	nextLive := 0
	for _, rt := range m.Routes {
		provider := snap.byID[rt.ProviderID]
		var health routeHealthView
		if provider != nil {
			health = states[nextLive]
			nextLive++
		}
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
		case health.phase() == healthCooling:
			state = api.AdminRouteStateCooling
		case health.phase() == healthProbing:
			state = api.AdminRouteStateProbing
		case health.phase() == healthProbeReady:
			state = api.AdminRouteStateProbeReady
		}
		v.Available = v.Available || state == api.AdminRouteStateReady || state == api.AdminRouteStateProbeReady
		v.Routes = append(v.Routes, api.AdminRoute{
			ProviderId: rt.ProviderID, UpstreamModel: rt.UpstreamModel,
			Priority: rt.Priority, Weight: rt.Weight, MaxBatch: rt.MaxBatch, Enabled: rt.Enabled,
			SupportsTools: rt.SupportsTools, SupportsImages: rt.SupportsImages,
			State: state, Health: adminHealthView(health.route),
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
// 返回去掉末尾斜杠的形式，请求时直接拼接 /responses 或 /embeddings。
func validBaseURL(raw string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", false
	}
	return strings.TrimRight(u.String(), "/"), true
}

// CreateProvider 新建一个来源。编号已经存在时返回 409，不覆盖原来源：重复填写
// 编号时地址与 key 一起被换掉，是一个不容易发现的事故，修改已有来源请用
// PutProvider。
func (a *Admin) CreateProvider(w http.ResponseWriter, r *http.Request) {
	var in api.AdminProviderInput
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	id := strings.TrimSpace(deref(in.Id, ""))
	if !ValidProviderID(id) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "id: lowercase letters, digits, - and _, at most 32")
		return
	}
	if _, err := a.catalog.Provider(r.Context(), id); err == nil {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "provider already exists; edit it instead")
		return
	} else if !errors.Is(err, ErrNotFound) {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	a.saveProvider(w, r, id, in, ProviderRecord{}, true)
}

// PutProvider 修改一个已有的来源，编号不存在时返回 404。新建来源请用
// CreateProvider。
func (a *Admin) PutProvider(w http.ResponseWriter, r *http.Request, id string) {
	if !ValidProviderID(id) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "id: lowercase letters, digits, - and _, at most 32")
		return
	}
	var in api.AdminProviderInput
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	if in.Id != nil && strings.TrimSpace(*in.Id) != id {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "id must match the path")
		return
	}
	rec, err := a.catalog.Provider(r.Context(), id)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, err)
		return
	}
	a.saveProvider(w, r, id, in, rec, false)
}

func (a *Admin) saveProvider(w http.ResponseWriter, r *http.Request, id string, in api.AdminProviderInput, rec ProviderRecord, created bool) {
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
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, a.providerView(saved))
}

func (a *Admin) DeleteProvider(w http.ResponseWriter, r *http.Request, id string) {
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

// CreateModel 新建一个对外模型。名称已经存在时返回 409，不覆盖原模型的路由：
// 在新增表单里误填一个已有名称会整体替换它的配置，修改已有模型请用 PutModel。
func (a *Admin) CreateModel(w http.ResponseWriter, r *http.Request) {
	var in api.AdminModelInput
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	name := strings.TrimSpace(deref(in.Name, ""))
	if !ValidModelName(name) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "name: letters, digits, . _ : -, at most 64, no slash")
		return
	}
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	if _, exists := snap.model(name); exists {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "model already exists; edit it instead")
		return
	}
	a.saveModel(w, r, name, nil, in, true)
}

// PutModel 修改一个已有的对外模型，名称不存在时返回 404。新建模型请用
// CreateModel。
func (a *Admin) PutModel(w http.ResponseWriter, r *http.Request, name string) {
	if !ValidModelName(name) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "name: letters, digits, . _ : -, at most 64, no slash")
		return
	}
	var in api.AdminModelInput
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	if in.Name != nil && strings.TrimSpace(*in.Name) != name {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "name must match the path")
		return
	}
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	old, exists := snap.model(name)
	if !exists {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	a.saveModel(w, r, name, old, in, false)
}

func (a *Admin) saveModel(w http.ResponseWriter, r *http.Request, name string, old *liveModel, in api.AdminModelInput, created bool) {
	rec, detail := modelRecord(name, in, a.now().UTC())
	if detail != "" {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, detail)
		return
	}
	// 改维度或改用途之后旧向量不再可用：先删这个模型的缓存，再保存。缓存删除
	// 失败时模型还没改，重试仍然会走清理；同名模型必须是同一个向量空间，换部署
	// 要换对外模型名，这条约束见 ADR-0029（ADR-0030 第 7 条）。
	if old != nil && (old.Kind != rec.Kind || old.Dimensions != rec.Dimensions) {
		if err := a.proxy.DeleteEmbeddingCache(r.Context(), name); err != nil {
			httpx.WriteInternal(w, r, a.proxy.log, err)
			return
		}
	}
	if err := a.catalog.PutModel(r.Context(), rec); err != nil {
		if errors.Is(err, ErrUnknownProvider) {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "routes: provider_id does not exist")
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
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, a.modelView(snap, saved))
}

// modelRecord 校验请求体并组装保存用的模型记录；第二个返回值是错误说明，为空
// 表示通过。
func modelRecord(name string, in api.AdminModelInput, now time.Time) (ModelRecord, string) {
	rec := ModelRecord{
		Name: name, Kind: Kind(in.Kind), Enabled: deref(in.Enabled, true),
		Note: strings.TrimSpace(deref(in.Note, "")), UpdatedAt: now,
	}
	switch rec.Kind {
	case KindChat:
		if in.Dimensions != nil {
			return rec, "dimensions only applies to embedding models"
		}
	case KindEmbedding:
		if in.Dimensions != nil {
			if *in.Dimensions < 1 || *in.Dimensions > 8192 {
				return rec, "dimensions: 1 to 8192"
			}
			rec.Dimensions = *in.Dimensions
		}
	default:
		return rec, "kind: chat or embedding"
	}
	if utf8.RuneCountInString(rec.Note) > 200 {
		return rec, "note is too long"
	}
	if len(in.Routes) == 0 || len(in.Routes) > 16 {
		return rec, "routes: 1 to 16"
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
			// 能力标记省略时按支持处理：旧版后台脚本不发送这两个字段，行为保持
			// 与加筛选之前一致。
			SupportsTools:  deref(ri.SupportsTools, true),
			SupportsImages: deref(ri.SupportsImages, true),
		}
		switch {
		case rt.UpstreamModel == "" || utf8.RuneCountInString(rt.UpstreamModel) > 128:
			return rec, "routes: upstream_model is required, at most 128 characters"
		case rt.Priority < 0 || rt.Priority > 100:
			return rec, "routes: priority 0 to 100"
		case rt.Weight < 1 || rt.Weight > 1000:
			return rec, "routes: weight 1 to 1000"
		case rt.MaxBatch < 0 || rt.MaxBatch > 2048:
			return rec, "routes: max_batch 0 to 2048"
		case seen[[2]string{rt.ProviderID, rt.UpstreamModel}]:
			return rec, "routes: duplicate provider_id and upstream_model"
		}
		seen[[2]string{rt.ProviderID, rt.UpstreamModel}] = true
		rec.Routes = append(rec.Routes, rt)
	}
	return rec, ""
}

func (a *Admin) DeleteModel(w http.ResponseWriter, r *http.Request, name string) {
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

// TestModel 使用正常路由次序或指定路由发出最小请求。探测更新相应的健康状态，
// 不计入账号额度与路由用量。
func (a *Admin) TestModel(w http.ResponseWriter, r *http.Request, name string, params api.PostAdminV1ModelsNameTestParams) {
	provider, upstream := deref(params.ProviderId, ""), deref(params.UpstreamModel, "")
	targeted := params.ProviderId != nil || params.UpstreamModel != nil
	if targeted && (provider == "" || len(provider) > 32 || upstream == "" || utf8.RuneCountInString(upstream) > 128) {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "supply provider_id (1–32 characters) and upstream_model (1–128 characters) together")
		return
	}
	snap, ok := a.fresh(w, r)
	if !ok {
		return
	}
	m, found := snap.model(name)
	if !found {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	trace := make([]api.AdminProbeAttempt, 0)
	out := api.AdminProbe{Attempts: &trace}
	plan := attemptPlan{model: m, targeted: targeted, trace: &trace}
	if targeted {
		idx := slices.IndexFunc(m.Live, func(route liveRoute) bool {
			return route.ProviderID == provider && route.UpstreamModel == upstream
		})
		if idx == -1 {
			httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "route not found")
			return
		}
		out.ProviderId, out.UpstreamModel = stringPointer(provider), stringPointer(upstream)
		if route := m.Live[idx]; m.Enabled && route.usable() {
			plan.candidates = []liveRoute{route}
		}
	} else {
		plan.candidates = a.router().candidates(m, "", capabilities{})
	}
	fail := func(msg string) {
		out.Error = &msg
		httpx.WriteJSON(w, http.StatusOK, out)
	}
	if len(plan.candidates) == 0 {
		fail("没有可尝试的路由，请检查启用状态、密钥和冷却状态")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	start := time.Now()
	if m.Kind == KindEmbedding {
		input, _ := json.Marshal([]string{"知新：把学过的内容找回来"})
		fields := map[string]json.RawMessage{"input": input}
		res := a.proxy.embed(ctx, &plan, fields, []string{"知新：把学过的内容找回来"})
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
			fail(probeFailure(trace, "没有发出嵌入请求"))
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
		"input":  json.RawMessage(`[{"type":"message","role":"user","content":"ping"}]`),
		"stream": json.RawMessage(`false`),
	}
	reply, err := a.proxy.dispatch(ctx, &plan, fields, false, defaultOutputTokens, time.Time{})
	out.LatencyMs = time.Since(start).Milliseconds()
	if err != nil || reply.completion != responseCompleted {
		if reply.route.Provider != nil {
			out.ProviderId, out.UpstreamModel = stringPointer(reply.route.ProviderID), stringPointer(reply.route.UpstreamModel)
		}
		if reply.status != 0 {
			out.Status = &reply.status
		}
		fail(probeFailure(trace, "没有发出聊天请求"))
		return
	}
	out.ProviderId, out.UpstreamModel = stringPointer(reply.route.ProviderID), stringPointer(reply.route.UpstreamModel)
	out.Status = &reply.status
	out.Ok = true
	httpx.WriteJSON(w, http.StatusOK, out)
}

func probeFailure(trace []api.AdminProbeAttempt, empty string) string {
	if len(trace) == 0 {
		return empty
	}
	return deref(trace[len(trace)-1].Error, "没有来源返回可用的响应")
}

// deref 是包内的转发入口，实现由 internal/deref 提供。同包的 keyusage.go 与
// usage.go 仍按这个名字调用，两处改用共用实现之后可以删掉这一层。
func deref[T any](value *T, fallback T) T { return sharedderef.Value(value, fallback) }

// stringPointer 取一个字符串的副本，返回的指针与调用处的变量无关。
func stringPointer(s string) *string { return &s }
