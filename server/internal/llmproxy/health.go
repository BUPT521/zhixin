package llmproxy

import (
	"net/http"
	"strconv"
	"sync"
	"time"
)

const (
	coolAfterFailures = 3
	coolBase          = 30 * time.Second
	coolMax           = 5 * time.Minute
)

type healthPhase uint8

const (
	healthReady healthPhase = iota
	healthProbeReady
	healthProbing
	healthCooling
)

func (p healthPhase) eligible() bool { return p <= healthProbeReady }

type healthKey struct {
	provider, model, upstream string
	kind                      Kind
}

func routeHealthKey(m *liveModel, rt liveRoute) healthKey {
	return healthKey{provider: rt.Provider.ID, model: m.Name, upstream: rt.UpstreamModel, kind: m.Kind}
}

type healthState struct {
	failures      int
	coolingUntil  time.Time
	lastError     string
	lastErrorAt   time.Time
	lastSuccessAt time.Time
	probing       bool
	generation    uint64
}

func (s healthState) phase(now time.Time) healthPhase {
	switch {
	case s.probing:
		return healthProbing
	case now.Before(s.coolingUntil):
		return healthCooling
	case !s.coolingUntil.IsZero():
		return healthProbeReady
	default:
		return healthReady
	}
}

// healthBook keeps independent process-local state for each provider and configured route.
type healthBook struct {
	mu  sync.Mutex
	m   map[healthKey]healthState
	now func() time.Time
}

func newHealthBook(now func() time.Time) *healthBook {
	return &healthBook{m: make(map[healthKey]healthState), now: now}
}

type healthView struct {
	healthState
	phase healthPhase
}

func (h *healthBook) view(key healthKey) healthView {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.m[key]
	return healthView{s, s.phase(h.now())}
}

type routeHealthView struct {
	source, route healthView
}

func (v routeHealthView) phase() healthPhase { return max(v.source.phase, v.route.phase) }

func (h *healthBook) modelViews(m *liveModel) []routeHealthView {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	out := make([]routeHealthView, len(m.Live))
	for i, rt := range m.Live {
		source := h.m[healthKey{provider: rt.Provider.ID}]
		route := h.m[routeHealthKey(m, rt)]
		out[i] = routeHealthView{healthView{source, source.phase(now)}, healthView{route, route.phase(now)}}
	}
	return out
}

type healthLease struct {
	key        healthKey
	generation uint64
	probe      bool
}

type routeLease struct {
	source, route healthLease
}

// acquire reserves both scopes under one lock. A targeted admin probe may enter cooling early.
func (h *healthBook) acquire(m *liveModel, rt liveRoute, targeted bool) (routeLease, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	sourceKey, routeKey := healthKey{provider: rt.Provider.ID}, routeHealthKey(m, rt)
	source, route := h.m[sourceKey], h.m[routeKey]
	for _, phase := range []healthPhase{source.phase(now), route.phase(now)} {
		if phase == healthProbing || (phase == healthCooling && !targeted) {
			return routeLease{}, false
		}
	}
	return routeLease{h.lease(sourceKey, source), h.lease(routeKey, route)}, true
}

func (h *healthBook) lease(key healthKey, s healthState) healthLease {
	probe := !s.coolingUntil.IsZero()
	if probe {
		s.probing = true
		h.m[key] = s
	}
	return healthLease{key, s.generation, probe}
}

type failureScope uint8

const (
	noHealthFailure failureScope = iota
	routeFailure
	sourceFailure
)

type healthOutcome struct {
	reason        string
	scope         failureScope
	sourceReached bool
	retryAfter    string
}

func (h *healthBook) complete(lease routeLease, success bool, outcome healthOutcome) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	sourceOK := success || (outcome.sourceReached && !lease.source.probe)
	h.completeScope(lease.source, sourceOK, outcome.scope == sourceFailure, outcome, now)
	h.completeScope(lease.route, success, outcome.scope == routeFailure, outcome, now)
}

func (h *healthBook) completeScope(lease healthLease, success, failed bool, outcome healthOutcome, now time.Time) {
	s := h.m[lease.key]
	if s.generation != lease.generation {
		return // this attempt started before a newer cooldown
	}
	s.probing = false
	switch {
	case failed:
		s.failures++
		s.lastError, s.lastErrorAt = outcome.reason, now
		retryAt := retryAfterTime(outcome.retryAfter, now)
		if lease.probe || s.failures >= coolAfterFailures {
			delay := coolBase << min(max(s.failures-coolAfterFailures, 0), 4)
			backoff := now.Add(min(delay, coolMax))
			if retryAt.Before(backoff) {
				retryAt = backoff
			}
		}
		if retryAt.Before(s.coolingUntil) {
			retryAt = s.coolingUntil
		}
		if retryAt.After(now) {
			s.coolingUntil = retryAt
			s.generation++
		}
	case success:
		s.failures, s.coolingUntil = 0, time.Time{}
		s.lastSuccessAt = now
	case !lease.probe:
		return
	}
	h.m[lease.key] = s
}

func retryAfterTime(value string, now time.Time) time.Time {
	if value == "" {
		return time.Time{}
	}
	if seconds, err := strconv.ParseUint(value, 10, 32); err == nil {
		return now.Add(time.Duration(seconds) * time.Second)
	}
	until, _ := http.ParseTime(value)
	return until
}
