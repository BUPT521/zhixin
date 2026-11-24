// Package payment handles one-time purchases of chat tokens through Alipay App Pay.
package payment

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"net/http"
	"strconv"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

const (
	Pending = "pending"
	Paid    = "paid"
	Closed  = "closed"
)

var ErrOrderNotFound = errors.New("payment: 订单不存在")

type Offer struct {
	AmountFen int64 `json:"amount_fen"`
	Tokens    int64 `json:"tokens"`
}

func (o Offer) id() string {
	return fmt.Sprintf("chat_%d_%d", o.AmountFen, o.Tokens)
}

type Order struct {
	Offer
	ID        string
	UserID    string
	AppID     string
	SellerID  string
	Sandbox   bool
	Status    string
	CreatedAt time.Time
	ExpiresAt time.Time
}

type Store interface {
	PurchaseBalance(ctx context.Context, userID string) (int64, error)
	LatestPurchase(ctx context.Context, userID string) (Order, error)
	FindPurchase(ctx context.Context, id string) (Order, error)
	CreatePurchase(ctx context.Context, order Order) (Order, error)
	ApplyPurchase(ctx context.Context, order Order, tradeID, status string) error
}

type Handler struct {
	store   Store
	gateway *Gateway
	offer   Offer
	log     *slog.Logger
	limit   *ratelimit.Limiter
	global  *ratelimit.Limiter
}

func NewHandler(store Store, gateway *Gateway, offer Offer, log *slog.Logger, rateKeys int) *Handler {
	return &Handler{
		store: store, gateway: gateway, offer: offer, log: log,
		limit:  ratelimit.New(0.5, 6, 15*time.Minute, rateKeys),
		global: ratelimit.NewGlobal(ratelimit.Limit{PerSecond: 12, Burst: 24}),
	}
}

type offerView struct {
	Offer
	ID      string `json:"id"`
	Sandbox bool   `json:"sandbox"`
}

type orderView struct {
	Offer
	ID        string    `json:"id"`
	OfferID   string    `json:"offer_id"`
	Status    string    `json:"status"`
	ExpiresAt time.Time `json:"expires_at"`
	Payable   bool      `json:"payable"`
	Sandbox   bool      `json:"sandbox"`
}

func (h *Handler) view(order Order, now time.Time) orderView {
	return orderView{
		Offer: order.Offer, ID: order.ID, OfferID: order.Offer.id(), Status: order.Status,
		ExpiresAt: order.ExpiresAt, Sandbox: order.Sandbox,
		Payable: order.Status == Pending && order.ExpiresAt.After(now) && h.matchesGateway(order),
	}
}

func (h *Handler) matchesGateway(order Order) bool {
	return h.gateway != nil && order.AppID == h.gateway.appID && order.SellerID == h.gateway.sellerID &&
		order.Sandbox == h.gateway.sandbox
}

func (h *Handler) Overview(w http.ResponseWriter, r *http.Request) {
	result := struct {
		Balance int64      `json:"balance_tokens"`
		Offer   *offerView `json:"offer,omitempty"`
		Latest  *orderView `json:"latest_order,omitempty"`
	}{}
	if h.store == nil {
		httpx.WriteJSON(w, http.StatusOK, result)
		return
	}
	p := auth.MustPrincipal(r.Context())
	balance, err := h.store.PurchaseBalance(r.Context(), p.UserID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	result.Balance = balance
	if h.gateway != nil && p.ContactVerified && h.offer.Tokens > 0 {
		result.Offer = &offerView{Offer: h.offer, ID: h.offer.id(), Sandbox: h.gateway.sandbox}
	}
	order, err := h.store.LatestPurchase(r.Context(), p.UserID)
	if err == nil {
		view := h.view(order, time.Now())
		result.Latest = &view
	} else if !errors.Is(err, ErrOrderNotFound) {
		h.writeError(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, result)
}

func (h *Handler) Checkout(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if h.store == nil || h.gateway == nil {
		h.writeError(w, r, ErrGateway)
		return
	}
	if !p.ContactVerified {
		httpx.WriteProblem(w, r, http.StatusForbidden, httpx.CodeContactUnverified, "")
		return
	}
	if !h.allow(w, r, p.UserID) {
		return
	}
	var input struct {
		OfferID string `json:"offer_id"`
		OrderID string `json:"order_id"`
	}
	if !httpx.DecodeJSON(w, r, 2048, &input) {
		return
	}
	now := time.Now().UTC()
	var order Order
	var err error
	if input.OrderID != "" {
		order, err = h.findOwned(r.Context(), p.UserID, input.OrderID)
	} else if h.offer.Tokens > 0 && input.OfferID == h.offer.id() {
		order, err = h.create(r.Context(), p.UserID, now)
	}
	if err != nil && !errors.Is(err, ErrOrderNotFound) {
		h.writeError(w, r, err)
		return
	}
	view := h.view(order, now)
	if !view.Payable || view.OfferID != input.OfferID {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "offer or Alipay order status has changed")
		return
	}
	orderString, err := h.gateway.signOrder(order, now)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		OrderString string    `json:"order_string"`
		Order       orderView `json:"order"`
	}{orderString, view})
}

func (h *Handler) create(ctx context.Context, userID string, now time.Time) (Order, error) {
	order, err := h.store.LatestPurchase(ctx, userID)
	if err != nil && !errors.Is(err, ErrOrderNotFound) {
		return Order{}, err
	}
	if order.Status == Pending && !order.ExpiresAt.After(now) {
		// 在开新单前查清旧单。已付款或仍可付款时，用户应先查看旧单。
		if !h.matchesGateway(order) {
			return Order{}, ErrGateway
		}
		result, err := h.gateway.query(ctx, order.ID, now)
		if err == nil && result.Status != "" {
			err = h.apply(ctx, order, result)
		}
		if err != nil {
			return Order{}, err
		}
		if result.Status != "" && result.Status != "TRADE_CLOSED" {
			return order, nil
		}
	}
	var random [16]byte
	rand.Read(random[:])
	return h.store.CreatePurchase(ctx, Order{
		ID: "zx_" + hex.EncodeToString(random[:]), UserID: userID, Offer: h.offer,
		AppID: h.gateway.appID, SellerID: h.gateway.sellerID, Sandbox: h.gateway.sandbox,
		Status: Pending, CreatedAt: now, ExpiresAt: now.Truncate(time.Second).Add(15 * time.Minute),
	})
}

func (h *Handler) findOwned(ctx context.Context, userID, id string) (Order, error) {
	order, err := h.store.FindPurchase(ctx, id)
	if err == nil && order.UserID != userID {
		err = ErrOrderNotFound
	}
	return order, err
}

func (h *Handler) Status(w http.ResponseWriter, r *http.Request, id string) {
	p := auth.MustPrincipal(r.Context())
	if h.store == nil {
		h.writeError(w, r, ErrOrderNotFound)
		return
	}
	order, err := h.findOwned(r.Context(), p.UserID, id)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	now := time.Now()
	if order.Status == Pending {
		// 回调可能先于查单到达。两条入口共用同一笔订单的原子入账。
		if !h.matchesGateway(order) {
			h.writeError(w, r, ErrGateway)
			return
		}
		if !h.allow(w, r, p.UserID) {
			return
		}
		result, err := h.gateway.query(r.Context(), id, now)
		if err == nil && result.Status != "" {
			err = h.apply(r.Context(), order, result)
		}
		if err != nil {
			h.writeError(w, r, err)
			return
		}
		order, err = h.store.FindPurchase(r.Context(), id)
		if err != nil {
			h.writeError(w, r, err)
			return
		}
	}
	httpx.WriteJSON(w, http.StatusOK, h.view(order, now))
}

func (h *Handler) Notify(w http.ResponseWriter, r *http.Request) {
	if h.store == nil || h.gateway == nil {
		http.Error(w, "failure", http.StatusNotFound)
		return
	}
	kind, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if kind != "application/x-www-form-urlencoded" {
		http.Error(w, "failure", http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "failure", http.StatusBadRequest)
		return
	}
	incoming, err := h.gateway.notification(r.PostForm)
	if err != nil {
		http.Error(w, "failure", http.StatusBadRequest)
		return
	}
	order, err := h.store.FindPurchase(r.Context(), incoming.OrderID)
	if err == nil {
		err = h.apply(r.Context(), order, incoming)
	}
	switch {
	case errors.Is(err, ErrInvalidTrade), errors.Is(err, ErrOrderNotFound):
		http.Error(w, "failure", http.StatusBadRequest)
	case err != nil:
		h.log.Error("apply Alipay notification", "order_id", order.ID, "error", err)
		http.Error(w, "failure", http.StatusInternalServerError)
	default:
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("success"))
	}
}

func (h *Handler) apply(ctx context.Context, order Order, result trade) error {
	value, err := amountFen(result.Amount)
	if err != nil || value != order.AmountFen || result.OrderID != order.ID ||
		!tradeID.MatchString(result.TradeID) || !h.matchesGateway(order) {
		return ErrInvalidTrade
	}
	switch result.Status {
	case "WAIT_BUYER_PAY":
		return nil
	case "TRADE_SUCCESS", "TRADE_FINISHED":
		if order.UserID == "" {
			h.log.Warn("paid Alipay order requires reconciliation after account deletion", "order_id", order.ID)
		}
		return h.store.ApplyPurchase(ctx, order, result.TradeID, Paid)
	case "TRADE_CLOSED":
		return h.store.ApplyPurchase(ctx, order, result.TradeID, Closed)
	default:
		return ErrInvalidTrade
	}
}

func (h *Handler) allow(w http.ResponseWriter, r *http.Request, userID string) bool {
	delay := h.limit.Take(userID)
	if delay == 0 {
		delay = h.global.TakeOne()
	}
	if delay == 0 {
		return true
	}
	w.Header().Set("Retry-After", strconv.FormatInt(delay, 10))
	httpx.WriteProblem(w, r, http.StatusTooManyRequests, httpx.CodeRateLimited, "try checking the Alipay order again later")
	return false
}

func (h *Handler) writeError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, ErrOrderNotFound):
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	case errors.Is(err, ErrGateway), errors.Is(err, ErrInvalidTrade):
		httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "Alipay payment status is temporarily unavailable")
	default:
		httpx.WriteInternal(w, r, h.log, err)
	}
}
