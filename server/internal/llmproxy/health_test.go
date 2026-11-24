package llmproxy

import (
	"net/http"
	"sync"
	"testing"
	"time"
)

func TestRetryAfterLimitsRouteRecovery(t *testing.T) {
	now := time.Date(2026, 11, 24, 10, 0, 0, 0, time.UTC)
	h := newHealthBook(func() time.Time { return now })
	m := &liveModel{ModelRecord: ModelRecord{Name: "m", Kind: KindChat}}
	p := &liveProvider{ProviderRecord: ProviderRecord{ID: "p"}}
	rt := liveRoute{Provider: p, Route: Route{UpstreamModel: "a"}}
	m.Live = []liveRoute{rt, {Provider: p, Route: Route{UpstreamModel: "b"}}}
	first, _ := h.acquire(m, rt, false)
	h.complete(first, false, httpFailure(http.StatusTooManyRequests, now.Add(2*time.Minute).Format(http.TimeFormat)))
	if states := h.modelViews(m); states[0].phase() != healthCooling || states[1].phase() != healthReady {
		t.Fatalf("Retry-After must cool only the affected route: %+v", states)
	}
	now = now.Add(time.Minute)
	if _, ok := h.acquire(m, rt, false); ok {
		t.Fatal("route must wait for Retry-After")
	}
	now = now.Add(time.Minute)
	probe, ok := h.acquire(m, rt, false)
	if !ok || !probe.route.probe {
		t.Fatal("route should be able to probe after Retry-After")
	}
	h.complete(probe, false, httpFailure(http.StatusTooManyRequests, "5"))
	if got := h.modelViews(m)[0].route.coolingUntil; !got.Equal(now.Add(coolBase)) {
		t.Fatalf("failed probe must renew local cooldown: %v", got)
	}
}

func TestHealthLimitsProbesAndIgnoresStaleResults(t *testing.T) {
	for _, tc := range []struct {
		name          string
		scope         failureScope
		siblingUsable bool
	}{
		{"route", routeFailure, true},
		{"source", sourceFailure, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			h := newHealthBook(func() time.Time { return now })
			m := &liveModel{ModelRecord: ModelRecord{Name: "m", Kind: KindChat}}
			p := &liveProvider{ProviderRecord: ProviderRecord{ID: "p"}}
			primary := liveRoute{Provider: p, Route: Route{UpstreamModel: "a"}}
			sibling := liveRoute{Provider: p, Route: Route{UpstreamModel: "b"}}
			m.Live = []liveRoute{primary, sibling}
			acquire := func(rt liveRoute) routeLease {
				t.Helper()
				attempt, ok := h.acquire(m, rt, false)
				if !ok {
					t.Fatal("route blocked")
				}
				return attempt
			}
			failure := healthOutcome{reason: "test failure", scope: tc.scope, sourceReached: tc.scope == routeFailure}
			staleSuccess := acquire(primary)
			for range coolAfterFailures {
				h.complete(acquire(primary), false, failure)
				if tc.siblingUsable {
					h.complete(acquire(sibling), true, healthOutcome{})
				}
			}
			h.complete(staleSuccess, true, healthOutcome{})
			states := h.modelViews(m)
			if states[0].phase() != healthCooling || states[1].phase().eligible() != tc.siblingUsable {
				t.Fatalf("unexpected cooldown: %+v", states)
			}
			if _, ok := h.acquire(m, primary, false); ok {
				t.Fatal("ordinary request entered active cooldown")
			}
			now = now.Add(coolBase)
			var wg sync.WaitGroup
			probes := make(chan routeLease, 16)
			for range cap(probes) {
				wg.Go(func() {
					if lease, ok := h.acquire(m, primary, false); ok {
						probes <- lease
					}
				})
			}
			wg.Wait()
			close(probes)
			if len(probes) != 1 || h.modelViews(m)[0].phase() != healthProbing {
				t.Fatalf("expected one concurrent probe, got %d", len(probes))
			}
			if _, ok := h.acquire(m, sibling, false); ok != tc.siblingUsable {
				t.Fatalf("unexpected sibling eligibility during probe: %t", ok)
			}
			h.complete(<-probes, false, healthOutcome{}) // cancellation releases the slot
			h.complete(acquire(primary), false, failure)
			now = now.Add(coolBase)
			if h.modelViews(m)[0].phase() != healthCooling {
				t.Fatal("failed probe should extend cooldown")
			}
			now = now.Add(coolBase)
			h.complete(acquire(primary), true, healthOutcome{})
			if states := h.modelViews(m); states[0].phase() != healthReady || states[1].phase() != healthReady {
				t.Fatalf("successful probe should restore routing: %+v", states)
			}
		})
	}
}
