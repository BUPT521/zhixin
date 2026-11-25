package nowpay

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"log/slog"

	"golang.org/x/sync/errgroup"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// 购买入口的状态。creating 表示已经占住幂等键、正在向即刻收创单，此时 purchase_url
// 为空；ready 表示链接可以打开；failed 表示这一次创单失败，下一次点击按同一个键重试。
const (
	PurchaseCreating = "creating"
	PurchaseReady    = "ready"
	PurchaseFailed   = "failed"
)

// creatingTTL 是 creating 行的占位有效期。创单成功之后换成即刻收给出的真实有效期；
// 超过它还是 creating，说明上一次创单中断了，下一次点击按同一个键重新创单。
const creatingTTL = 15 * time.Minute

// Purchase 是一次购买入口请求。ClientRequestNo 是客户端每次点击生成的幂等键，
// OutRequestNo 是提交给即刻收的创单请求号，State 见上面三个常量。
type Purchase struct {
	OutRequestNo    string
	ClientRequestNo string
	SKU             string
	URL             string
	State           string
	ExpiresAt       time.Time
}

// PurchaseStore 保存购买入口请求，由 store/pg 实现。同一账号同一幂等键的并发点击由
// LockPurchase 串行化，因此幂等判断、创单与落库不会交错（ADR-0074）。
type PurchaseStore interface {
	LatestPurchaseLink(ctx context.Context, userID string, now time.Time) (Purchase, bool, error)
	PurchaseByClientRequestNo(ctx context.Context, userID, clientRequestNo string) (Purchase, bool, error)
	CreatePurchaseLink(ctx context.Context, userID string, purchase Purchase) error
	ReplacePurchaseLink(ctx context.Context, userID string, purchase Purchase) error
	ReadyPurchaseLink(ctx context.Context, outRequestNo, url string, expiresAt time.Time) error
	FailPurchaseLink(ctx context.Context, outRequestNo string) error
	LockPurchase(ctx context.Context, userID, clientRequestNo string, fn func(context.Context) error) error
}

// BalanceStore 保存积分余额的本地副本，由 store/pg 实现。额度预留按这份副本放行
// 免费额度之外的用量，所以每次查到余额都要写回；asOf 是这份余额对应的快照时刻，
// 晚到的旧快照不会覆盖新副本（ADR-0069、ADR-0073）。
type BalanceStore interface {
	SaveBalance(ctx context.Context, userID string, remaining int64, asOf time.Time) error
}

// Handler 提供查商品与余额、取购买链接、单独查余额三个接口。客户端只负责打开链接
// 和刷新余额，能不能买、扣了多少都由服务端按即刻收的结果判断。
type Handler struct {
	client    *Client
	purchases PurchaseStore
	balances  BalanceStore
	callback  string
	log       *slog.Logger
	limit     *ratelimit.Limiter
	global    *ratelimit.Limiter

	// tokensPerPoint 是一个积分覆盖的计费 token 数，概览接口原样返回，供客户端把
	// 积分换算成 token；比例只有配置一处来源，由 config.Load 校验为正数。
	tokensPerPoint int64

	// capability 是商品收费能力的进程内缓存：概览页每次打开都查一次商品没有意义，
	// 六十秒内复用上一次的结果；购买入口直接查实时状态，不读这份缓存。
	capMu        sync.Mutex
	capability   Capability
	capabilityAt time.Time
}

// capabilityTTL 是商品收费能力的缓存时间。审核与下架不会在几十秒内反复变化，缓存
// 让概览页少一次网关调用，同时保留一分钟内感知变化的窗口。
const capabilityTTL = time.Minute

// NewHandler 装配三个接口。client 为空表示没有配置即刻收商品，接口只返回空余额。
// tokensPerPoint 由调用方传入已经校验过的配置值，这里不再设默认值，避免配置与
// 核销各按一套比例。
func NewHandler(client *Client, purchases PurchaseStore, balances BalanceStore, callback string,
	log *slog.Logger, rateKeys int, tokensPerPoint int64) *Handler {
	if log == nil {
		log = slog.Default()
	}
	return &Handler{
		client: client, purchases: purchases, balances: balances, callback: callback, log: log,
		limit:          ratelimit.New(0.5, 6, 15*time.Minute, rateKeys),
		global:         ratelimit.NewGlobal(ratelimit.Limit{PerSecond: 12, Burst: 24}),
		tokensPerPoint: tokensPerPoint,
	}
}

// Overview 返回商品收费能力与积分余额。商品查询成功就带上状态，客户端
// 按 capability_status 决定是否显示购买入口；商品查询与余额查询并行，余额失败不再
// 让整页 503，而是返回商品信息并标记 balance_unavailable，客户端提示暂时查不到余额。
func (h *Handler) Overview(w http.ResponseWriter, r *http.Request) {
	principal := auth.MustPrincipal(r.Context())
	view := api.QuotaPurchaseOverview{TokensPerPoint: h.tokensPerPoint}
	if h.client == nil || !principal.ContactVerified {
		httpx.WriteJSON(w, http.StatusOK, view)
		return
	}
	if !h.allow(w, r, principal.UserID) {
		return
	}
	var (
		capability Capability
		balance    Balance
		capErr     error
		balanceErr error
	)
	group, ctx := errgroup.WithContext(r.Context())
	group.Go(func() error {
		capability, capErr = h.chargeCapability(ctx)
		return nil
	})
	group.Go(func() error {
		balance, balanceErr = h.client.Balance(ctx, principal.UserID)
		return nil
	})
	_ = group.Wait()
	if capErr != nil {
		h.unavailable(w, r, "查询即刻收商品", capErr)
		return
	}
	view.Product = productView(capability)
	switch {
	case balanceErr != nil:
		h.log.Error("query the nowpay balance for the overview",
			"user_id", principal.UserID, "error", balanceErr)
		unavailable := true
		view.BalanceUnavailable = &unavailable
	case balance.Unit != UnitPoints:
		// 商品的积分单位不是 POINT 时不能按积分展示与放行，也不写副本；商品信息
		// 照常返回，让客户端看到“暂时查不到余额”而不是整页失败（ADR-0073）。
		h.log.Error("the nowpay product is not sold in points",
			"user_id", principal.UserID, "quota_unit", balance.Unit)
		unavailable := true
		view.BalanceUnavailable = &unavailable
	default:
		view.BalancePoints = balance.Remaining
		h.saveBalance(r.Context(), principal.UserID, balance.Remaining, balance.AsOf)
	}
	if h.purchases != nil {
		existing, ok, err := h.purchases.LatestPurchaseLink(r.Context(), principal.UserID, time.Now())
		if err != nil {
			h.log.Error("read nowpay purchase link", "user_id", principal.UserID, "error", err)
		} else if ok {
			view.LatestPurchase = linkView(existing)
		}
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}

// chargeCapability 返回商品收费能力，六十秒内复用上一次的结果。缓存只给概览页用：
// 购买入口要按当前状态决定能不能创单，直接查实时状态。
func (h *Handler) chargeCapability(ctx context.Context) (Capability, error) {
	h.capMu.Lock()
	if !h.capabilityAt.IsZero() && time.Since(h.capabilityAt) < capabilityTTL {
		cached := h.capability
		h.capMu.Unlock()
		return cached, nil
	}
	h.capMu.Unlock()
	capability, err := h.client.Charge(ctx)
	if err != nil {
		return Capability{}, err
	}
	h.capMu.Lock()
	h.capability = capability
	h.capabilityAt = time.Now()
	h.capMu.Unlock()
	return capability, nil
}

// Balance 只查积分余额，供购买页返回之后刷新使用。
func (h *Handler) Balance(w http.ResponseWriter, r *http.Request) {
	principal := auth.MustPrincipal(r.Context())
	if h.client == nil {
		httpx.WriteJSON(w, http.StatusOK, api.QuotaBalance{})
		return
	}
	if !h.allow(w, r, principal.UserID) {
		return
	}
	balance, err := h.client.Balance(r.Context(), principal.UserID)
	if err != nil {
		h.unavailable(w, r, "查询即刻收积分余额", err)
		return
	}
	if balance.Unit != UnitPoints {
		// 商品不是按积分卖时，余额数字不能按积分展示，也不写进放行用的副本。
		h.log.Error("the nowpay product is not sold in points",
			"user_id", principal.UserID, "quota_unit", balance.Unit)
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict,
			"the product is not sold in points")
		return
	}
	h.saveBalance(r.Context(), principal.UserID, balance.Remaining, balance.AsOf)
	httpx.WriteJSON(w, http.StatusOK, api.QuotaBalance{
		Remaining: balance.Remaining, Total: balance.Total, Used: balance.Used,
	})
}

// saveBalance 把查到的余额写进本地副本，额度预留据此放行免费额度之外的用量。写
// 失败不影响这次查询的结果，下一次查询或核销会再写一遍。
func (h *Handler) saveBalance(ctx context.Context, userID string, remaining int64, asOf time.Time) {
	if h.balances == nil {
		return
	}
	if err := h.balances.SaveBalance(ctx, userID, remaining, asOf); err != nil {
		h.log.Error("save nowpay balance", "user_id", userID, "error", err)
	}
}

// Purchase 取一个托管购买页链接。价格与档位由即刻收给出，服务端只按 sku_id 锁定
// 档位。客户端每次点击生成一个 client_request_no：同一个键重试复用同一张链接，换一次
// 点击换一个键就一定拿新链接；支付成功之后再点不会拿到已经付过的页面（ADR-0074）。
// 旧客户端不传键时服务端生成一个随机键，行为等同于每次点击都新链接，不报错。
func (h *Handler) Purchase(w http.ResponseWriter, r *http.Request) {
	principal := auth.MustPrincipal(r.Context())
	if h.client == nil {
		h.unavailable(w, r, "获取购买链接", errors.New("即刻收商品未配置"))
		return
	}
	if !principal.ContactVerified {
		httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeContactUnverified, "")
		return
	}
	if !h.allow(w, r, principal.UserID) {
		return
	}
	var input struct {
		SKUID           string `json:"sku_id"`
		ClientRequestNo string `json:"client_request_no"`
	}
	if !httpx.DecodeJSON(w, r, 1024, &input) {
		return
	}
	clientRequestNo := strings.TrimSpace(input.ClientRequestNo)
	if len(clientRequestNo) > 64 {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"client_request_no must be at most 64 characters")
		return
	}
	if clientRequestNo == "" {
		clientRequestNo = newPurchaseID()
	}
	capability, err := h.client.Charge(r.Context())
	if err != nil {
		h.unavailable(w, r, "查询即刻收商品", err)
		return
	}
	if !capability.Purchasable() {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict,
			"the product is not open for new purchases ("+capability.Status+")")
		return
	}
	if capability.BillingMode != BillingQuantity || capability.QuotaUnit != UnitPoints {
		// 只有按积分的数量包能接进额度放行；其它收费模式的档位金额不是积分，
		// 创单之后无法按积分抵扣，这里直接拒绝。
		h.log.Error("the nowpay product is not a point package",
			"billing_mode", capability.BillingMode, "quota_unit", capability.QuotaUnit)
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict,
			"the product is not sold in points")
		return
	}
	if input.SKUID != "" && !hasOption(capability.Options, input.SKUID) {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "the sku is not on sale")
		return
	}
	now := time.Now()
	request := Purchase{ClientRequestNo: clientRequestNo, SKU: input.SKUID}
	var purchase Purchase
	if h.purchases != nil {
		err = h.purchases.LockPurchase(r.Context(), principal.UserID, clientRequestNo, func(ctx context.Context) error {
			resolved, flowErr := h.purchaseLink(ctx, principal.UserID, request, now)
			purchase = resolved
			return flowErr
		})
	} else {
		purchase, err = h.purchaseLink(r.Context(), principal.UserID, request, now)
	}
	if err != nil {
		h.unavailable(w, r, "获取即刻收购买链接", err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, linkView(purchase))
}

// purchaseLink 在 (账号, 幂等键) 的锁里决定这次点击复用、重试还是新创一个入口，再
// 调用一次 purchase.create 取链接。调用方必须已经持有这个键的锁，否则同一键的两次
// 并发点击会各创一张链接。
func (h *Handler) purchaseLink(ctx context.Context, userID string, request Purchase, now time.Time) (Purchase, error) {
	purchase := request
	if h.purchases != nil {
		existing, ok, err := h.purchases.PurchaseByClientRequestNo(ctx, userID, request.ClientRequestNo)
		if err != nil {
			return Purchase{}, err
		}
		switch {
		case ok && existing.State == PurchaseReady && existing.URL != "" && existing.ExpiresAt.After(now):
			// 同一个键已经有一张可用链接：原样返回，不再创单。
			return existing, nil
		case ok && existing.State == PurchaseCreating && existing.ExpiresAt.After(now):
			// 上一次创单停在同一请求号上：按原号重试，即刻收按幂等返回同一张链接。
			purchase = existing
		case ok:
			// 失败、超时或已过期：换一个请求号重新创单，替换这一行。
			purchase = Purchase{
				OutRequestNo: newPurchaseID(), ClientRequestNo: request.ClientRequestNo,
				SKU: request.SKU, State: PurchaseCreating, ExpiresAt: now.Add(creatingTTL),
			}
			if err := h.purchases.ReplacePurchaseLink(ctx, userID, purchase); err != nil {
				h.log.Error("replace nowpay purchase link", "user_id", userID, "error", err)
			}
		default:
			// 这个键还没有入口：先落一条 creating 占位，再创单。
			purchase = Purchase{
				OutRequestNo: newPurchaseID(), ClientRequestNo: request.ClientRequestNo,
				SKU: request.SKU, State: PurchaseCreating, ExpiresAt: now.Add(creatingTTL),
			}
			if err := h.purchases.CreatePurchaseLink(ctx, userID, purchase); err != nil {
				// 插入失败不回 503：链接仍然可以给出，只是这次点击没有落库。
				h.log.Error("insert nowpay purchase link", "user_id", userID, "error", err)
			}
		}
	} else {
		purchase = Purchase{
			OutRequestNo: newPurchaseID(), ClientRequestNo: request.ClientRequestNo,
			SKU: request.SKU, State: PurchaseCreating, ExpiresAt: now.Add(creatingTTL),
		}
	}
	if purchase.OutRequestNo == "" {
		purchase.OutRequestNo = newPurchaseID()
	}
	link, err := h.client.Purchase(ctx, PurchaseRequest{
		OutRequestNo: purchase.OutRequestNo, Buyer: userID,
		SKU: purchase.SKU, CallbackURL: h.callback,
	})
	if err != nil {
		// 创单失败记 failed，下一次点击用同一个键再试；请求号保留在行里。
		if h.purchases != nil {
			markCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			if markErr := h.purchases.FailPurchaseLink(markCtx, purchase.OutRequestNo); markErr != nil {
				h.log.Error("mark nowpay purchase link failed",
					"user_id", userID, "error", markErr)
			}
			cancel()
		}
		return Purchase{}, err
	}
	purchase.URL, purchase.ExpiresAt, purchase.State = link.URL, link.ExpiresAt, PurchaseReady
	if h.purchases != nil {
		markCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		if markErr := h.purchases.ReadyPurchaseLink(markCtx, purchase.OutRequestNo, link.URL, link.ExpiresAt); markErr != nil {
			// 链接照常返回；下一次点击读到 creating 会按原请求号重试，不会重复创单。
			h.log.Error("record the nowpay purchase link", "user_id", userID, "error", markErr)
		}
		cancel()
	}
	return purchase, nil
}

// allow 按账号与实例两层限流；超出时回 429 并带上重试秒数。
func (h *Handler) allow(w http.ResponseWriter, r *http.Request, userID string) bool {
	delay := h.limit.Take(userID)
	if delay == 0 {
		delay = h.global.TakeOne()
	}
	if delay == 0 {
		return true
	}
	w.Header().Set("Retry-After", strconv.FormatInt(delay, 10))
	httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "try again later")
	return false
}

// unavailable 记下真实原因，对外只说即刻收暂时不可用，不把上游错误码写进响应。
func (h *Handler) unavailable(w http.ResponseWriter, r *http.Request, step string, err error) {
	h.log.Error("nowpay call failed", "step", step, "error", err)
	httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable,
		"now pay is temporarily unavailable")
}

func productView(capability Capability) *api.QuotaPurchaseProduct {
	options := make([]api.QuotaPurchaseOption, 0, len(capability.Options))
	for _, option := range capability.Options {
		options = append(options, api.QuotaPurchaseOption{
			SkuId: option.SKU, DisplayName: option.Name, Price: option.Price, QuotaAmount: option.Quota,
		})
	}
	return &api.QuotaPurchaseProduct{
		CapabilityStatus: api.QuotaPurchaseProductCapabilityStatus(capability.Status),
		BillingMode:      api.QuotaPurchaseProductBillingMode(capability.BillingMode),
		QuotaUnit:        api.QuotaPurchaseProductQuotaUnit(capability.QuotaUnit),
		Options:          options,
	}
}

func linkView(purchase Purchase) *api.QuotaPurchaseLink {
	link := &api.QuotaPurchaseLink{
		OutRequestNo: purchase.OutRequestNo, PurchaseUrl: purchase.URL, ExpiresAt: purchase.ExpiresAt,
	}
	if purchase.SKU != "" {
		sku := purchase.SKU
		link.SkuId = &sku
	}
	return link
}

func hasOption(options []Option, sku string) bool {
	for _, option := range options {
		if option.SKU == sku {
			return true
		}
	}
	return false
}

func newPurchaseID() string { return newID("np_") }
