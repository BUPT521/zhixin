package llmproxy

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
)

type attemptPlan struct {
	model      *liveModel
	candidates []liveRoute
	reserve    attemptBudget
	targeted   bool
	trace      *[]api.AdminProbeAttempt

	started     int
	skipSources map[string]bool
}

type routeAttempt struct {
	lease  routeLease
	settle finishAttempt
}

func (p *Proxy) beginAttempt(ctx context.Context, plan *attemptPlan, rt liveRoute, estimate int64) (routeAttempt, bool, error) {
	if err := ctx.Err(); err != nil {
		return routeAttempt{}, false, err
	}
	if plan.skipSources[rt.Provider.ID] {
		return routeAttempt{}, false, nil
	}
	lease, ok := p.router.health.acquire(plan.model, rt, plan.targeted)
	if !ok {
		return routeAttempt{}, false, nil
	}
	settle, err := plan.reserve.start(rt, estimate, plan.started == 0)
	if err != nil {
		p.router.health.complete(lease, false, healthOutcome{})
		return routeAttempt{}, false, err
	}
	if err := ctx.Err(); err != nil {
		p.router.health.complete(lease, false, healthOutcome{})
		settle(attemptResult{notSent: true})
		return routeAttempt{}, false, err
	}
	plan.started++
	return routeAttempt{lease, settle}, true, nil
}

func (p *Proxy) attemptsRemain(plan *attemptPlan) bool {
	return p.cfg.MaxAttempts <= 0 || plan.started < p.cfg.MaxAttempts
}

func (p *Proxy) finishAttempt(plan *attemptPlan, attempt routeAttempt, result attemptResult, status int, outcome healthOutcome) {
	p.router.health.complete(attempt.lease, result.success, outcome)
	if outcome.scope == sourceFailure {
		if plan.skipSources == nil {
			plan.skipSources = make(map[string]bool)
		}
		plan.skipSources[attempt.lease.source.key.provider] = true
	}
	if plan.trace != nil {
		key := attempt.lease.route.key
		trace := api.AdminProbeAttempt{
			ProviderId: key.provider, UpstreamModel: key.upstream, Ok: result.success,
			RecoveryProbe: attempt.lease.source.probe || attempt.lease.route.probe,
		}
		if status != 0 {
			trace.Status = &status
		}
		if outcome.reason != "" {
			trace.Error = &outcome.reason
		}
		*plan.trace = append(*plan.trace, trace)
	}
	attempt.settle(result)
}

// A 401 rejects the shared credential. Other HTTP errors may be specific to the model.
func httpFailure(status int, retryAfter string) healthOutcome {
	out := healthOutcome{reason: fmt.Sprintf("HTTP %d", status), sourceReached: true}
	switch {
	case status == http.StatusUnauthorized:
		out.scope, out.sourceReached = sourceFailure, false
	case retryable(status):
		out.scope = routeFailure
	}
	if status == http.StatusTooManyRequests || status == http.StatusServiceUnavailable {
		out.retryAfter = retryAfter
	}
	return out
}

type sourceConnectionError struct{ error }

func (e sourceConnectionError) Unwrap() error { return e.error }

func requestFailure(ctx context.Context, err error) healthOutcome {
	if ctx.Err() != nil {
		return healthOutcome{reason: "请求已取消或超时"}
	}
	var connection sourceConnectionError
	if errors.As(err, &connection) {
		return healthOutcome{reason: "无法连接模型来源", scope: sourceFailure}
	}
	return healthOutcome{reason: "未收到模型响应", scope: routeFailure}
}
