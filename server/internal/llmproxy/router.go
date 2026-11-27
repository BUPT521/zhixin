package llmproxy

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
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

// liveProvider 是快照里的来源，key 已经解密。
type liveProvider struct {
	ProviderRecord
	APIKey string
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
	Live []liveRoute
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

// Router 持有当前路由表与来源、路由的健康状态。
type Router struct {
	catalog Catalog
	box     *secretbox.Box
	log     *slog.Logger
	health  *healthBook

	snap     atomic.Pointer[snapshot]
	reloadMu sync.Mutex
	// warned 记录已经报过“key 无法解密”的密文，周期刷新时不重复写日志。
	warned map[string]bool
	// shuffle 打乱同一优先级内的候选，测试里换成确定的顺序。
	shuffle func([]liveRoute)
	// sticky 按会话和模型记录故障期间接手的路由，超过有效期后恢复原调度顺序。
	stickyMu sync.Mutex
	sticky   map[stickySession]stickyRoute
	now      func() time.Time
}

// 备路由接手之后，同一条讨论在这段时间内继续从接手的路由开始，不马上回切到已经
// 恢复的主路由。回切会把备用来源上已经热起来的前缀丢掉，下一次追问又要重新处理
// 整段历史；时间太长又会把配置好的主路由压住，所以只覆盖恢复初期的几轮追问。
const (
	stickyAfterTakeover = 10 * time.Minute
	maxStickySessions   = 4096
)

type stickySession struct {
	session, model string
	kind           Kind
}

// stickyRoute 是某条讨论当前偏好的路由，until 之后失效。
type stickyRoute struct {
	provider, upstream string
	until              time.Time
}

// NewRouter 建立路由器，初始快照是空的；调用方随后执行一次 Reload 读入管理
// 后台配置的来源与模型。box 为 nil 时无法解密任何保存的 key。
func NewRouter(catalog Catalog, box *secretbox.Box, log *slog.Logger) *Router {
	r := &Router{
		catalog: catalog,
		box:     box,
		log:     log,
		health:  newHealthBook(time.Now),
		shuffle: weightedShuffle,
		warned:  map[string]bool{},
		now:     time.Now,
	}
	r.snap.Store(r.build(nil, nil))
	return r
}

func (r *Router) current() *snapshot { return r.snap.Load() }

// ModelCount 是当前快照里的对外模型数，用于启动日志与运维核对。
func (r *Router) ModelCount() int { return len(r.current().models) }

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

func (r *Router) build(providers []ProviderRecord, models []ModelRecord) *snapshot {
	s := &snapshot{byID: map[string]*liveProvider{}, byName: map[string]*liveModel{}}

	for _, rec := range providers {
		p := &liveProvider{ProviderRecord: rec}
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
		m := &liveModel{ModelRecord: rec}
		for _, route := range rec.Routes {
			p, ok := s.byID[route.ProviderID]
			if !ok {
				continue // 外键保证存在；防御性跳过
			}
			m.Live = append(m.Live, liveRoute{Route: route, Provider: p})
		}
		s.byName[rec.Name] = m
	}
	for _, m := range s.byName {
		s.models = append(s.models, m)
	}
	sort.Slice(s.models, func(i, j int) bool { return s.models[i].Name < s.models[j].Name })
	return s
}

// capabilities 是这次请求需要路由具备的能力：声明了 tools 就要求函数调用，输入
// 里带图片就要求视觉。两类标记都由管理员在后台按实际调用核对。
type capabilities struct{ tools, images bool }

// candidates 按优先级分组，组内按权重排列。执行前还要重新检查健康状态并占用
// 试探名额。session 非空时组内顺序由会话与权重确定，同一会话的追问与工具步骤
// 因此优先使用同一条来源；为空时每次请求按权重随机排列。
// need 里要求的能力对应的标记为假时，这条路由不进入候选。
func (r *Router) candidates(m *liveModel, session string, need capabilities) []liveRoute {
	if !m.Enabled {
		return nil
	}
	var usable []liveRoute
	states := r.health.modelViews(m)
	for i, rt := range m.Live {
		if !rt.usable() || !states[i].phase().eligible() {
			continue
		}
		if need.tools && !rt.SupportsTools {
			continue
		}
		if need.images && !rt.SupportsImages {
			continue
		}
		usable = append(usable, rt)
	}
	sort.SliceStable(usable, func(i, j int) bool { return usable[i].Priority < usable[j].Priority })
	for start := 0; start < len(usable); {
		end := start
		for end < len(usable) && usable[end].Priority == usable[start].Priority {
			end++
		}
		if session == "" {
			r.shuffle(usable[start:end])
		} else {
			sessionOrder(usable[start:end], session)
		}
		start = end
	}
	r.preferSticky(stickySession{session: session, model: m.Name, kind: m.Kind}, usable)
	return usable
}

// rememberTakeover 记下这条讨论由哪条路由接手。只在首次尝试失败、后续尝试成功时
// 调用：按会话顺序本来就该落到的来源不需要再记。
func (r *Router) rememberTakeover(session string, key healthKey) {
	if session == "" {
		return
	}
	r.stickyMu.Lock()
	defer r.stickyMu.Unlock()
	if r.sticky == nil {
		r.sticky = make(map[stickySession]stickyRoute)
	}
	if len(r.sticky) >= maxStickySessions {
		r.pruneSticky()
	}
	r.sticky[stickySession{session: session, model: key.model, kind: key.kind}] = stickyRoute{provider: key.provider, upstream: key.upstream, until: r.now().Add(stickyAfterTakeover)}
}

// preferSticky 把这条讨论接手的路由提到候选最前面。健康状态、启用状态与本次需要
// 的能力在进入候选时已经筛过，接手的路由不可用就仍按原顺序落到下一条。
func (r *Router) preferSticky(session stickySession, usable []liveRoute) {
	if session.session == "" || len(usable) < 2 {
		return
	}
	r.stickyMu.Lock()
	entry, ok := r.sticky[session]
	if ok && !r.now().Before(entry.until) {
		delete(r.sticky, session)
		ok = false
	}
	r.stickyMu.Unlock()
	if !ok {
		return
	}
	for i, rt := range usable {
		if rt.Provider.ID != entry.provider || rt.UpstreamModel != entry.upstream {
			continue
		}
		copy(usable[1:i+1], usable[:i])
		usable[0] = rt
		return
	}
}

// pruneSticky 清掉过期的记录；清完仍然占满时整体放手，回到按会话顺序分配，避免
// 长时间运行之后只增不减。
func (r *Router) pruneSticky() {
	now := r.now()
	for session, entry := range r.sticky {
		if !now.Before(entry.until) {
			delete(r.sticky, session)
		}
	}
	if len(r.sticky) >= maxStickySessions {
		clear(r.sticky)
	}
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
	sortByKey(rs, keys)
}

// sessionOrder 按会话给同一优先级内的候选排一个确定的顺序：会话与每条候选各算
// 一个 (0,1] 的数，再按权重做同样的不放回抽样。同一会话每次得到同一个顺序，
// 同组权重表示会话落到各条路由的比例，不再是每次请求的抽签比例；会话进入冷却
// 或停用之后，它按这个顺序落到下一条还能用的候选上，顺序本身仍然稳定。
func sessionOrder(rs []liveRoute, session string) {
	if len(rs) < 2 {
		return
	}
	keys := make([]float64, len(rs))
	for i, rt := range rs {
		keys[i] = math.Pow(sessionUnit(session, rt), 1/float64(max(rt.Weight, 1)))
	}
	sortByKey(rs, keys)
}

// sortByKey 按 key 从大到小重排 rs，顺序稳定。
func sortByKey(rs []liveRoute, keys []float64) {
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

// sessionUnit 把会话与一条候选映射成 (0,1] 之间的数。同一会话与同一候选永远
// 得到同一个数，换会话或换候选就换成另一组数。用 SHA-256 的高 53 位：散列均匀
// 才能让加权抽样按权重分开会话，取 53 位是因为 float64 的尾数正好是 53 位。
func sessionUnit(session string, rt liveRoute) float64 {
	sum := sha256.Sum256([]byte(session + "\x00" + rt.Provider.ID + "\x00" + rt.UpstreamModel))
	value := binary.BigEndian.Uint64(sum[:8]) >> 11
	return (float64(value) + 1) / (float64(uint64(1)<<53) + 1)
}

func keyHint(key string) string {
	if len(key) <= 4 {
		return ""
	}
	return key[len(key)-4:]
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
