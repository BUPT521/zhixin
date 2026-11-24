package pg

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/payment"
)

func TestPostgresPurchaseCreditsOnceAndPaysForChatOnly(t *testing.T) {
	st := newTestStore(t)
	ctx := t.Context()
	st.purchasedQuotaEnabled = true
	st.purchasedQuotaSandbox = true
	if err := createAccount(ctx, st, auth.User{ID: "buyer", PasswordHash: "h"}, "buyer@example.invalid"); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	order := payment.Order{
		ID: "zx_1", UserID: "buyer", AppID: "test_app", SellerID: "test_seller", Sandbox: true,
		Offer: payment.Offer{AmountFen: 99, Tokens: 50}, CreatedAt: now, ExpiresAt: now.Add(15 * time.Minute),
	}
	created, err := st.CreatePurchase(ctx, order)
	if err != nil {
		t.Fatal(err)
	}
	retry := order
	retry.ID = "zx_duplicate"
	if same, err := st.CreatePurchase(ctx, retry); err != nil || same.ID != created.ID {
		t.Fatalf("checkout retry gave %s: %v", same.ID, err)
	}
	var wg sync.WaitGroup
	for range 8 {
		wg.Go(func() {
			if err := st.ApplyPurchase(ctx, created, "12345", payment.Paid); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	assertBalance := func(want int64) {
		t.Helper()
		if got, err := st.PurchaseBalance(ctx, "buyer"); err != nil || got != want {
			t.Fatalf("balance = %d, want %d (err=%v)", got, want, err)
		}
	}
	assertBalance(50)
	st.purchasedQuotaSandbox = false
	assertBalance(0)
	st.purchasedQuotaSandbox = true
	st.SetQuotaLimits(100, 20, 0)
	const day = "2026-11-25"
	reserve := func(day string, kind llmproxy.Kind, want, expected int64) {
		t.Helper()
		got, err := st.Reserve(ctx, "buyer", day, kind, "", want)
		if got != expected || err != nil {
			t.Fatalf("reserve = %d, want %d (err=%v)", got, expected, err)
		}
	}
	reserve(day, llmproxy.KindEmbedding, 30, 20)
	reserve(day, llmproxy.KindChat, 80, 80)
	assertBalance(50)
	reserve(day, llmproxy.KindChat, 40, 40)
	assertBalance(30)
	if err := st.Settle(ctx, "buyer", day, llmproxy.KindChat, "", 40, 25, llmproxy.Usage{}); err != nil {
		t.Fatal(err)
	}
	assertBalance(45)
	reserve(day, llmproxy.KindChat, 60, 45)
	if _, err := st.Reserve(ctx, "buyer", day, llmproxy.KindChat, "", 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("empty wallet should give quota exceeded: %v", err)
	}
	if err := st.Settle(ctx, "buyer", day, llmproxy.KindChat, "", 45, 10, llmproxy.Usage{}); err != nil {
		t.Fatal(err)
	}
	assertBalance(35)
	reserve("2026-11-26", llmproxy.KindChat, 100, 100)
	assertBalance(35)
	if err := st.DeleteUser(ctx, "buyer"); err != nil {
		t.Fatal(err)
	}
	assertBalance(0)
	saved, err := st.FindPurchase(ctx, order.ID)
	if err != nil || saved.UserID != "" || saved.Status != payment.Paid {
		t.Fatalf("paid order should survive with no account link: %+v (%v)", saved, err)
	}
}
