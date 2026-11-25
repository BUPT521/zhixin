package nowpay

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"log/slog"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// Purchase 是一次购买入口请求，保存请求号是为了在同一档位上重试时复用原链接。
type Purchase struct {
	OutRequestNo string
	SKU          string
	URL          string
	ExpiresAt    time.Time
}

// PurchaseStore 保存购买入口请求，由 store/pg 实现。
type PurchaseStore interface {
	LatestPurchaseLink(ctx context.Context, userID string, now time.Time) (Purchase, bool, error)
	InsertPurchaseLink(ctx context.Context, userID string, purchase Purchase) error
}

// BalanceStore 保存积分余额的本地副本，由 store/pg 实现。额度预留按这份副本放行
// 免费额度之外的用量，所以每次查到余额都要写回（ADR-0069）。
type BalanceStore interface {
	SaveBalance(ctx context.Context, userID string, remaining int64) error
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
}

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

// Overview 返回商品收费能力、积分余额与遗留余额。商品查询成功就带上状态，客户端
// 按 capability_status 决定是否显示购买入口；余额查询失败不按零处理。
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
	capability, err := h.client.Charge(r.Context())
	if err != nil {
		h.unavailable(w, r, "查询即刻收商品", err)
		return
	}
	balance, err := h.client.Balance(r.Context(), principal.UserID)
	if err != nil {
		h.unavailable(w, r, "查询即刻收积分余额", err)
		return
	}
	view.Product = productView(capability)
	view.BalancePoints = balance.Remaining
	h.saveBalance(r.Context(), principal.UserID, balance.Remaining)
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
	h.saveBalance(r.Context(), principal.UserID, balance.Remaining)
	httpx.WriteJSON(w, http.StatusOK, api.QuotaBalance{
		Remaining: balance.Remaining, Total: balance.Total, Used: balance.Used,
	})
}

// saveBalance 把查到的余额写进本地副本，额度预留据此放行免费额度之外的用量。写
// 失败不影响这次查询的结果，下一次查询或核销会再写一遍。
func (h *Handler) saveBalance(ctx context.Context, userID string, remaining int64) {
	if h.balances == nil {
		return
	}
	if err := h.balances.SaveBalance(ctx, userID, remaining); err != nil {
		h.log.Error("save nowpay balance", "user_id", userID, "error", err)
	}
}

// Purchase 取一个托管购买页链接。价格与档位由即刻收给出，服务端只按 sku_id 锁定
// 档位；同一档位在链接有效期内重试时复用原链接，不重复创单。
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
		SKUID string `json:"sku_id"`
	}
	if !httpx.DecodeJSON(w, r, 1024, &input) {
		return
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
	if input.SKUID != "" && !hasOption(capability.Options, input.SKUID) {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "the sku is not on sale")
		return
	}
	now := time.Now()
	if h.purchases != nil {
		existing, ok, err := h.purchases.LatestPurchaseLink(r.Context(), principal.UserID, now)
		if err != nil {
			h.unavailable(w, r, "读取购买链接", err)
			return
		}
		if ok && existing.SKU == input.SKUID {
			httpx.WriteJSON(w, http.StatusOK, linkView(existing))
			return
		}
	}
	purchase := Purchase{OutRequestNo: newPurchaseID(), SKU: input.SKUID}
	link, err := h.client.Purchase(r.Context(), PurchaseRequest{
		OutRequestNo: purchase.OutRequestNo, Buyer: principal.UserID,
		SKU: input.SKUID, CallbackURL: h.callback,
	})
	if err != nil {
		h.unavailable(w, r, "获取即刻收购买链接", err)
		return
	}
	purchase.URL, purchase.ExpiresAt = link.URL, link.ExpiresAt
	if h.purchases != nil {
		if err := h.purchases.InsertPurchaseLink(r.Context(), principal.UserID, purchase); err != nil {
			h.unavailable(w, r, "保存购买链接", err)
			return
		}
	}
	httpx.WriteJSON(w, http.StatusOK, linkView(purchase))
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
