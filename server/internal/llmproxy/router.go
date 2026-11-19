package llmproxy

import (
	"context"
	"log/slog"
	"math"
	"math/rand/v2"
	"slices"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// EnvSource 是环境变量给出的来源：一个地址、一把 key 与两组模型名。它在
// 管理后台之外保留一条不依赖数据库的配置路径，第一套实例升级之后不用先进
// 后台就能继续工作；同名模型以管理后台的配置为准。
type EnvSource struct {
	BaseURL         string
	APIKey          string
	ChatModels      []string
	EmbeddingModels []string
}

const (
	sourceAdmin = "admin"
	sourceEnv   = "env"
)

// liveProvider 是快照里的来源，key 已经解密。
type liveProvider struct {
	ProviderRecord
	APIKey string
	Source string
	// KeyBroken 表示保存的 key 无法用当前 ZHIXIN_SECRET_KEY 解密，这个来源
	// 不参与路由，管理后台显示为 key_error。
	KeyBroken bool
}

type liveRoute struct {
	Route
	Provider *liveProvider
}

func (r liveRoute) usable() bool {
	return r.Enabled && r.Provider.Enabled && !r.Provider.KeyBroken
}

type liveModel struct {
	ModelRecord
	Source string
	Live   []liveRoute
}

// usable 报告这个模型现在能不能对客户端提供：启用并且至少有一条可用路由。
func (m *liveModel) usable() bool {
	if !m.Enabled {
		return false
	}
	for _, r := range m.Live {
		if r.usable() {
			return true
		}
	}
	return false
}

// snapshot 是某一时刻的完整路由表。请求只读快照，管理后台改配置之后整体换新，
// 不加锁也不会读到改了一半的配置。
type snapshot struct {
	providers []*liveProvider
	models    []*liveModel
	byID      map[string]*liveProvider
	byName    map[string]*liveModel
}

func (s *snapshot) model(name string) (*liveModel, bool) {
	m, ok := s.byName[name]
	return m, ok
}

// Router 持有当前路由表与各来源的健康状态。
type Router struct {
	catalog Catalog
	box     *secretbox.Box
	env     EnvSource
	log     *slog.Logger
	health  *healthBook

	snap     atomic.Pointer[snapshot]
	reloadMu sync.Mutex
	// warned 记录已经报过“key 无法解密”的密文，周期刷新时不重复写日志。
	warned map[string]bool
	// shuffle 打乱同一优先级内的候选，测试里换成确定的顺序。
	shuffle func([]liveRoute)
}

// NewRouter 建立路由器，初始快照只含环境变量来源；调用方随后执行一次 Reload
// 读入管理后台的配置。box 为 nil 时无法解密任何保存的 key。
func NewRouter(catalog Catalog, box *secretbox.Box, env EnvSource, log *slog.Logger) *Router {
	r := &Router{
		catalog: catalog,
		box:     box,
		env:     env,
		log:     log,
		health:  newHealthBook(time.Now),
		shuffle: weightedShuffle,
		warned:  map[string]bool{},
	}
	r.snap.Store(r.build(nil, nil))
	return r
}

func (r *Router) current() *snapshot { return r.snap.Load() }

// Reload 从 Catalog 重新读取配置并换上新快照。读取失败时保留旧快照并返回错误，
// 数据库短暂不可用不会让正在工作的路由消失。
func (r *Router) Reload(ctx context.Context) error {
	r.reloadMu.Lock()
	defer r.reloadMu.Unlock()
	if r.catalog == nil {
		return nil
	}
	providers, err := r.catalog.Providers(ctx)
	if err != nil {
		return err
	}
	models, err := r.catalog.Models(ctx)
	if err != nil {
		return err
	}
	r.snap.Store(r.build(providers, models))
	return nil
}

// RunReloadLoop 每隔 every 重新读取一次配置，让直接改库或多实例部署时的修改
// 也能生效；管理接口保存之后会立即 Reload，不等这个周期。
func (r *Router) RunReloadLoop(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := r.Reload(ctx); err != nil && ctx.Err() == nil {
				r.log.Error("reload model routes", slog.String("error", err.Error()))
			}
		}
	}
}

func (r *Router) build(providers []ProviderRecord, models []ModelRecord) *snapshot {
	s := &snapshot{byID: map[string]*liveProvider{}, byName: map[string]*liveModel{}}

	if r.env.APIKey != "" && r.env.BaseURL != "" {
		envP := &liveProvider{
			ProviderRecord: ProviderRecord{
				ID: EnvProviderID, Name: "环境变量", BaseURL: r.env.BaseURL,
				KeyHint: keyHint(r.env.APIKey), Enabled: true,
				Note: "改环境变量并重启生效",
			},
			APIKey: r.env.APIKey,
			Source: sourceEnv,
		}
		s.providers = append(s.providers, envP)
		s.byID[EnvProviderID] = envP
		add := func(names []string, kind Kind) {
			for _, name := range names {
				if _, dup := s.byName[name]; dup {
					continue
				}
				route := Route{ProviderID: EnvProviderID, UpstreamModel: name, Weight: 1, Enabled: true}
				m := &liveModel{
					ModelRecord: ModelRecord{Name: name, Kind: kind, Enabled: true, Routes: []Route{route}},
					Source:      sourceEnv,
					Live:        []liveRoute{{Route: route, Provider: envP}},
				}
				s.byName[name] = m
			}
		}
		add(r.env.ChatModels, KindChat)
		add(r.env.EmbeddingModels, KindEmbedding)
	}

	for _, rec := range providers {
		p := &liveProvider{ProviderRecord: rec, Source: sourceAdmin}
		if rec.APIKeySealed != "" {
			if r.box == nil {
				p.KeyBroken = true
			} else if key, err := r.box.Open(rec.APIKeySealed, KeyAAD(rec.ID, rec.BaseURL)); err != nil {
				p.KeyBroken = true
			} else {
				p.APIKey = key
			}
			if p.KeyBroken && !r.warned[rec.APIKeySealed] {
				r.warned[rec.APIKeySealed] = true
				r.log.Error("model provider key cannot be decrypted; check ZHIXIN_SECRET_KEY", slog.String("provider", rec.ID))
			}
		}
		s.providers = append(s.providers, p)
		s.byID[rec.ID] = p
	}

	for _, rec := range models {
		m := &liveModel{ModelRecord: rec, Source: sourceAdmin}
		for _, route := range rec.Routes {
			p, ok := s.byID[route.ProviderID]
			if !ok || p.Source != sourceAdmin {
				continue // 外键保证存在；防御性跳过
			}
			m.Live = append(m.Live, liveRoute{Route: route, Provider: p})
		}
		s.byName[rec.Name] = m // 管理后台的同名模型覆盖环境变量
	}
	for _, m := range s.byName {
		s.models = append(s.models, m)
	}
	sort.Slice(s.models, func(i, j int) bool { return s.models[i].Name < s.models[j].Name })
	return s
}

// candidates 给出一次请求依次尝试的路由：按优先级从小到大分组，组内按权重
// 随机排列；正在冷却的来源挪到最后，只在其余来源都失败时才试。最多 max 条。
func (r *Router) candidates(m *liveModel, max int) []liveRoute {
	var usable []liveRoute
	for _, rt := range m.Live {
		if rt.usable() {
			usable = append(usable, rt)
		}
	}
	sort.SliceStable(usable, func(i, j int) bool { return usable[i].Priority < usable[j].Priority })
	for start := 0; start < len(usable); {
		end := start
		for end < len(usable) && usable[end].Priority == usable[start].Priority {
			end++
		}
		r.shuffle(usable[start:end])
		start = end
	}
	var fresh, cooling []liveRoute
	for _, rt := range usable {
		if r.health.cooling(rt.Provider.ID) {
			cooling = append(cooling, rt)
		} else {
			fresh = append(fresh, rt)
		}
	}
	out := append(fresh, cooling...)
	if max > 0 && len(out) > max {
		out = out[:max]
	}
	return out
}

// weightedShuffle 按权重做不放回抽样（Efraimidis–Spirakis）：权重大的更常
// 排在前面，但每条路由都有机会先被选中。
func weightedShuffle(rs []liveRoute) {
	if len(rs) < 2 {
		return
	}
	keys := make([]float64, len(rs))
	for i, rt := range rs {
		w := float64(max(rt.Weight, 1))
		// u^(1/w) 越大越靠前；u 取 (0,1]。
		keys[i] = math.Pow(1-rand.Float64(), 1/w)
	}
	idx := make([]int, len(rs))
	for i := range idx {
		idx[i] = i
	}
	sort.Slice(idx, func(a, b int) bool { return keys[idx[a]] > keys[idx[b]] })
	sorted := make([]liveRoute, len(rs))
	for i, k := range idx {
		sorted[i] = rs[k]
	}
	copy(rs, sorted)
}

func keyHint(key string) string {
	if len(key) <= 4 {
		return ""
	}
	return key[len(key)-4:]
}

// healthBook 记录各来源最近的调用结果。连续失败三次之后进入冷却，冷却时间从
// 30 秒起每次翻倍，最长 5 分钟；成功一次清零。只在本进程内有效。
type healthBook struct {
	mu  sync.Mutex
	m   map[string]*providerHealth
	now func() time.Time
}

type providerHealth struct {
	failures      int
	coolingUntil  time.Time
	lastError     string
	lastErrorAt   time.Time
	lastSuccessAt time.Time
}

const (
	coolAfterFailures = 3
	coolBase          = 30 * time.Second
	coolMax           = 5 * time.Minute
)

func newHealthBook(now func() time.Time) *healthBook {
	return &healthBook{m: map[string]*providerHealth{}, now: now}
}

func (h *healthBook) get(id string) *providerHealth {
	ph, ok := h.m[id]
	if !ok {
		ph = &providerHealth{}
		h.m[id] = ph
	}
	return ph
}

func (h *healthBook) fail(id, reason string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	ph := h.get(id)
	now := h.now()
	ph.failures++
	ph.lastError = reason
	ph.lastErrorAt = now
	if ph.failures >= coolAfterFailures {
		d := coolBase << min(ph.failures-coolAfterFailures, 4)
		ph.coolingUntil = now.Add(min(d, coolMax))
	}
}

func (h *healthBook) succeed(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	ph := h.get(id)
	ph.failures = 0
	ph.coolingUntil = time.Time{}
	ph.lastSuccessAt = h.now()
}

func (h *healthBook) cooling(id string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	ph, ok := h.m[id]
	return ok && h.now().Before(ph.coolingUntil)
}

func (h *healthBook) view(id string) providerHealth {
	h.mu.Lock()
	defer h.mu.Unlock()
	if ph, ok := h.m[id]; ok {
		return *ph
	}
	return providerHealth{}
}

// routeNames 是错误信息里列出的模型名，只含可用的指定种类。
func (s *snapshot) modelNames(kind Kind) []string {
	var names []string
	for _, m := range s.models {
		if m.Kind == kind && m.usable() {
			names = append(names, m.Name)
		}
	}
	return slices.Clip(names)
}
