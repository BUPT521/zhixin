package llmproxy

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

type attemptResult struct {
	// usage 是来源报告的原始用量，额度结算、账号统计与路由统计都从这里取数。
	// unknown 表示这次没有拿到 usage（请求失败、来源不报用量），结算改用估算。
	usage   Usage
	unknown bool
	// estimated 是没有拿到上游用量的部分按输入估算的原始 token 数，只进后台
	// 用量统计的估算列，不参与扣减：扣减只认 usage，拿不到就记 0。结算时由
	// billedTokens 补齐；嵌入按批次已经算过一部分的沿用那一份。
	estimated int64
	// unbilled 表示这次尝试不向账号结算：请求没有发出、连接都没有建立，来源
	// 明确拒绝（非 2xx），或者来源虽然回了 2xx 却没有可核对的上游用量（页面、
	// 错误体、正文根本没有读）。来源回了带 usage 或能解析成响应对象的整段响应时
	// 按用量的口径结算，不记 0（ADR-0070）；嵌入只要没有一批带回 usage 就按这条
	// 记 0，估算的输入只进统计（ADR-0084）。
	unbilled bool
	// outputEstimate 是已经转给客户端的输出 token 估算；没有 usage 时按它加
	// 输入估算结算，不沿用预留量。
	outputEstimate int64

	success        bool
	notSent        bool
	outputLimited  bool
	clientCanceled bool
}

type finishAttempt func(attemptResult)

// attemptBudget reserves quota and supplies a completion function for a route.
// A nil budget is used for admin probes.
type attemptBudget func(liveRoute, Usage, bool) (finishAttempt, error)

func (budget attemptBudget) start(route liveRoute, estimate Usage, first bool) (finishAttempt, error) {
	if budget == nil {
		return func(attemptResult) {}, nil
	}
	return budget(route, estimate, first)
}

type quotaReservationError struct{ cause error }

func (e quotaReservationError) Error() string { return e.cause.Error() }
func (e quotaReservationError) Unwrap() error { return e.cause }

func (p *Proxy) budget(r *http.Request, userID, day string, model *liveModel) attemptBudget {
	// 用量记到这次调用所用的模型代理密钥上；用访问令牌时编号为空字符串。
	keyID := auth.MustPrincipal(r.Context()).KeyID
	return func(route liveRoute, estimate Usage, first bool) (finishAttempt, error) {
		want := p.quotaCost(model.Kind, estimate.reserve(model.Kind))
		// Reserve 要么拿到完整的 want，要么返回带原因的错误；不再按剩余量截断，
		// 因此这里不需要退回预留，429 也能说清是哪种额度用完（ADR-0071）。
		reserved, err := p.quota.Reserve(r.Context(), userID, day, model.Kind, keyID, want)
		if err != nil {
			return nil, quotaReservationError{cause: err}
		}
		return func(result attemptResult) {
			var attempt SettleAttempt
			if !result.notSent {
				attempt = attemptOf(!result.success)
			}
			billed := p.quotaCost(model.Kind, billedTokens(model.Kind, estimate, &result))
			// 结算失败不能让回答失败：内容已经交付。预留的补退与待补偿记录由额度
			// 实现负责，这里只留下一条能对上请求与用量的日志（ADR-0086）。
			if err := p.settle(r, userID, day, model.Kind, keyID, reserved, billed, result.usage, attempt); err != nil {
				p.log.Error("settle llm usage",
					slog.String("request_id", httpx.RequestIDFrom(r.Context())),
					slog.String("user_id", userID),
					slog.String("day", day),
					slog.String("kind", string(model.Kind)),
					slog.String("api_key_id", keyID),
					slog.Int64("reserved_tokens", reserved),
					slog.Int64("billed_tokens", billed),
					slog.String("error", err.Error()))
			}
			if p.usage == nil || result.notSent {
				return
			}
			canceled := result.clientCanceled || r.Context().Err() != nil
			p.recordRouteUsage(r.Context(), RouteUsage{
				Day: day,
				RouteUsageKey: RouteUsageKey{
					Kind: model.Kind, Model: model.Name, ProviderID: route.ProviderID, UpstreamModel: route.UpstreamModel,
				},
				UsageCounts: routeAttemptUsage(model.Kind, result, first, canceled),
			})
		}, nil
	}
}

// routeAttemptUsage records raw upstream tokens separately from quota settlement.
func routeAttemptUsage(kind Kind, result attemptResult, first, canceled bool) UsageCounts {
	counts := UsageCounts{Attempts: 1, InputTokens: result.usage.Input, CachedTokens: result.usage.Cached}
	// 估算列每次都记同一份数字：没有来源用量的尝试由 billedTokens 填好，按 0
	// 结算的尝试因此也留得下原本的量。
	counts.EstimatedTokens = result.estimated
	switch {
	case result.unbilled:
		// 上游拒绝请求或没有带回用量时按 0 结算，保留尝试次数；估算的输入只记
		// 进估算列，后台看得见这类尝试原本的量。
	case result.usage.Total() > 0:
		counts.Tokens = result.usage.Total()
	default:
		// 没有来源用量、按估算结算：Token 合计与估算列是同一个数。
		counts.Tokens = result.estimated
	}
	if first {
		counts.FirstAttempts = 1
	} else {
		counts.FailoverAttempts = 1
	}
	counts.recordCache(kind, first, result.usage)
	switch {
	case result.success:
		counts.Successes = 1
	case result.outputLimited:
		counts.TruncatedAttempts = 1
	case canceled:
		counts.CanceledAttempts = 1
	}
	return counts
}

// billedTokens 返回一次尝试应当记的计费 token 数，并把估算列要记的原始 token
// 写回 result.estimated。有 usage 就按 usage；没有 usage 时按输入估算与已经转出
// 的输出估算结算，确定没有产生上游费用的失败记 0，不再沿用预留量。估算仍按未
// 命中缓存的输入折算，与客户端发请求前的判断同口径。
//
// 估算列与结算在同一处得出：来源没有报告用量时两边是同一份数字，嵌入按批次算过
// 一部分的沿用那一部分。后台因此分得清哪一笔按估算记账、哪一笔有来源用量。
func billedTokens(kind Kind, estimate Usage, result *attemptResult) int64 {
	if result.estimated <= 0 {
		result.estimated = estimatedTokens(estimate, *result)
	}
	switch {
	case result.notSent || result.unbilled:
		return 0
	case result.usage.Total() > 0:
		return result.usage.Billed(kind)
	case result.outputEstimate > 0:
		return Usage{Input: estimate.Input, Output: result.outputEstimate}.Billed(kind)
	default:
		return Usage{Input: estimate.Input}.Billed(kind)
	}
}

// estimatedTokens 返回一次尝试按输入与已转出输出估算的原始 token 数：来源报告了
// 用量，或者请求根本没有发出时返回 0，其余情况就是结算用的那份估算。嵌入按批次
// 已经算过一部分时由嵌入自己写进 result.estimated，不经过这里。
func estimatedTokens(estimate Usage, result attemptResult) int64 {
	if result.notSent || result.usage.Total() > 0 {
		return 0
	}
	return estimate.Input + result.outputEstimate
}

func (p *Proxy) recordRouteUsage(ctx context.Context, row RouteUsage) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := p.usage.AddRouteUsage(ctx, row); err != nil {
		p.log.Error("record llm route usage", slog.String("request_id", httpx.RequestIDFrom(ctx)), slog.String("error", err.Error()))
	}
}

// settle 即使客户端断开也结算本次预留。reserved 与 actual 都是计费 token，
// usage 是来源报告的原始用量，只用于统计缓存命中，不参与扣减；attempt 是这次
// 尝试与它是否失败，只进 llm_usage 的尝试统计，让后台看得见按 0 结算的调用。
//
// 返回的错误由调用方记日志，不能就地丢掉：reserved_tokens 只有结算会减，一次失败
// 就留下这笔预留一直占着当天的额度，所以失败时额度实现要退回预留或者留下一条待补
// 偿记录（ADR-0086）。
func (p *Proxy) settle(r *http.Request, userID, day string, kind Kind, keyID string, reserved, actual int64, usage Usage, attempt SettleAttempt) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	return p.quota.Settle(ctx, userID, day, kind, keyID, reserved, actual, usage, attempt)
}
