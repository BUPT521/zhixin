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
	// session 是这条讨论的调度键；首次尝试失败、后面的来源接住时，按它记住接手的
	// 路由，短时间内同一条讨论继续从那里开始。
	session string
	// background 表示这次请求可以等，只能用没有留给前台的内存与并发名额。
	background bool

	started     int
	skipSources map[string]bool
}

type routeAttempt struct {
	lease  routeLease
	settle finishAttempt
}

func (p *Proxy) beginAttempt(ctx context.Context, plan *attemptPlan, rt liveRoute, estimate Usage) (routeAttempt, bool, error) {
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
	if result.success && plan.started > 1 {
		// 首次尝试失败之后的成功说明这条来源接住了这轮请求。短时间内让同一条讨论
		// 继续从它开始，避免主来源恢复后马上回切，把备用来源上已经热起来的前缀丢掉。
		p.router.rememberTakeover(plan.session, attempt.lease.route.key)
	}
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

// 401 说明这把共用的凭据被上游拒绝，402 说明凭据背后的账户没有余额或额度，
// 两者都会让同一来源的其他路由一起失败，因此按来源级故障处理；其他状态码可能
// 只与这个模型有关，按路由级故障处理。取舍见 ADR-0075。
func httpFailure(status int, retryAfter string) healthOutcome {
	out := healthOutcome{reason: fmt.Sprintf("HTTP %d", status), sourceReached: true}
	switch {
	case status == http.StatusUnauthorized || status == http.StatusPaymentRequired:
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

// 健康原因里两段跨文件复用的文案：代理的流式收尾、尝试结束与嵌入都会写它们，
// 会进后台探测的 trace.Error，同一件事只维护一份写法。
const (
	healthReasonRoundBudget = "本轮预算用完"
	healthReasonCanceled    = "请求已取消或超时"
)

// 两类停止原因的健康状态是固定的：预算用完按到达来源处理，请求取消不算来源
// 故障。代理收尾与 requestFailure 直接引用，不在每处重写。
var (
	roundBudgetHealth = healthOutcome{reason: healthReasonRoundBudget, sourceReached: true}
	canceledHealth    = healthOutcome{reason: healthReasonCanceled}
)

func requestFailure(ctx context.Context, err error) healthOutcome {
	if ctx.Err() != nil {
		return canceledHealth
	}
	var connection sourceConnectionError
	if errors.As(err, &connection) {
		return healthOutcome{reason: "无法连接模型来源", scope: sourceFailure}
	}
	return healthOutcome{reason: "未收到模型响应", scope: routeFailure}
}
