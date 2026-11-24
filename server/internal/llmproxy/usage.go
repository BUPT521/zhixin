package llmproxy

import (
	"cmp"
	"context"
	"fmt"
	"net/http"
	"slices"
	"sync"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	openapi_types "github.com/oapi-codegen/runtime/types"
)

// RouteUsageKey identifies a route independently of the current catalog, so
// past usage remains visible after the route is removed.
type RouteUsageKey struct {
	Kind                             Kind
	Model, ProviderID, UpstreamModel string
}

type UsageCounts struct {
	Attempts, FirstAttempts, FailoverAttempts, Successes int64
	TruncatedAttempts, CanceledAttempts                  int64
	Tokens, EstimatedTokens                              int64
	// InputTokens 是来源报告的输入量，CachedTokens 是其中命中上游缓存的部分。
	// 两者都只在上游给出 usage 时记录，缺失时保持 0，缓存命中占比按有数据的
	// 请求单独计算（方案第 7 节）。
	InputTokens, CachedTokens int64
}

func (u *UsageCounts) add(other UsageCounts) {
	u.Attempts += other.Attempts
	u.FirstAttempts += other.FirstAttempts
	u.FailoverAttempts += other.FailoverAttempts
	u.Successes += other.Successes
	u.TruncatedAttempts += other.TruncatedAttempts
	u.CanceledAttempts += other.CanceledAttempts
	u.Tokens += other.Tokens
	u.EstimatedTokens += other.EstimatedTokens
	u.InputTokens += other.InputTokens
	u.CachedTokens += other.CachedTokens
}

func (u UsageCounts) view() api.AdminUsageCounts {
	return api.AdminUsageCounts{
		Attempts: u.Attempts, FirstAttempts: u.FirstAttempts, FailoverAttempts: u.FailoverAttempts,
		TruncatedAttempts: u.TruncatedAttempts, CanceledAttempts: u.CanceledAttempts,
		Successes: u.Successes, Tokens: u.Tokens, EstimatedTokens: u.EstimatedTokens,
		InputTokens: u.InputTokens, CachedTokens: u.CachedTokens,
	}
}

// RouteUsage is an aggregate for one route on a local calendar day. It contains
// no account identifiers or user content.
type RouteUsage struct {
	Day string
	RouteUsageKey
	UsageCounts
}

type UsageStore interface {
	AddRouteUsage(context.Context, RouteUsage) error
	RouteUsage(ctx context.Context, from, to string) ([]RouteUsage, error)
}

type MemoryUsage struct {
	mu   sync.Mutex
	days map[string]map[RouteUsageKey]UsageCounts
}

func NewMemoryUsage() *MemoryUsage {
	return &MemoryUsage{days: make(map[string]map[RouteUsageKey]UsageCounts)}
}

func (s *MemoryUsage) AddRouteUsage(_ context.Context, row RouteUsage) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	routes := s.days[row.Day]
	if routes == nil {
		routes = make(map[RouteUsageKey]UsageCounts)
		s.days[row.Day] = routes
	}
	counts := routes[row.RouteUsageKey]
	counts.add(row.UsageCounts)
	routes[row.RouteUsageKey] = counts
	return nil
}

func (s *MemoryUsage) RouteUsage(_ context.Context, from, to string) ([]RouteUsage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var rows []RouteUsage
	for day, routes := range s.days {
		if day < from || day > to {
			continue
		}
		for key, counts := range routes {
			rows = append(rows, RouteUsage{Day: day, RouteUsageKey: key, UsageCounts: counts})
		}
	}
	return rows, nil
}

// SetUsageStore is called during server assembly, before serving requests.
func (p *Proxy) SetUsageStore(store UsageStore) { p.usage = store }

func (a *Admin) Usage(w http.ResponseWriter, r *http.Request, params api.GetAdminV1UsageParams) {
	days := deref(params.Days, 7)
	if days < 1 || days > 30 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "days: 1 to 30")
		return
	}
	if a.proxy.usage == nil {
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "route usage storage is not configured")
		return
	}
	today := a.proxy.dayTime()
	first := today.AddDate(0, 0, 1-days)
	const dateFormat = "2006-01-02"
	rows, err := a.proxy.usage.RouteUsage(r.Context(), first.Format(dateFormat), today.Format(dateFormat))
	if err != nil {
		httpx.WriteInternal(w, r, a.proxy.log, fmt.Errorf("read route usage: %w", err))
		return
	}
	type dayCounts struct{ chat, embedding UsageCounts }
	byDay := make(map[string]dayCounts, days)
	type routeCounts struct {
		total UsageCounts
		daily map[string]api.AdminUsageCounts
	}
	byRoute := make(map[RouteUsageKey]routeCounts)
	for _, row := range rows {
		day := byDay[row.Day]
		if row.Kind == KindChat {
			day.chat.add(row.UsageCounts)
		} else {
			day.embedding.add(row.UsageCounts)
		}
		byDay[row.Day] = day
		route := byRoute[row.RouteUsageKey]
		if route.daily == nil {
			route.daily = make(map[string]api.AdminUsageCounts)
		}
		route.total.add(row.UsageCounts)
		route.daily[row.Day] = row.UsageCounts.view()
		byRoute[row.RouteUsageKey] = route
	}
	out := api.AdminUsageReport{
		Timezone: today.Location().String(),
		Daily:    make([]api.AdminUsageDay, 0, days),
		Routes:   make([]api.AdminUsageRoute, 0, len(byRoute)),
	}
	for i := range days {
		date := first.AddDate(0, 0, i)
		day := byDay[date.Format(dateFormat)]
		out.Daily = append(out.Daily, api.AdminUsageDay{
			Day: openapi_types.Date{Time: date}, Chat: day.chat.view(), Embedding: day.embedding.view(),
		})
	}
	for key, counts := range byRoute {
		out.Routes = append(out.Routes, api.AdminUsageRoute{
			Kind: api.ModelKind(key.Kind), Model: key.Model, ProviderId: key.ProviderID,
			UpstreamModel: key.UpstreamModel, Usage: counts.total.view(), Daily: counts.daily,
		})
	}
	slices.SortFunc(out.Routes, func(a, b api.AdminUsageRoute) int {
		return cmp.Or(cmp.Compare(b.Usage.Tokens, a.Usage.Tokens), cmp.Compare(a.Kind, b.Kind),
			cmp.Compare(a.Model, b.Model), cmp.Compare(a.ProviderId, b.ProviderId), cmp.Compare(a.UpstreamModel, b.UpstreamModel))
	})
	httpx.WriteJSON(w, http.StatusOK, out)
}
