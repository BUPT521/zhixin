package pg

import (
	"context"
	"errors"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/nowpay"
)

func TestChargeableTokensSubtractsTheFreeAllowance(t *testing.T) {
	for _, test := range []struct {
		name              string
		used, limit, want int64
	}{
		{"没有用量", 0, 200000, 0},
		{"免费额度够用", 150000, 200000, 0},
		{"刚好用完免费额度", 200000, 200000, 0},
		{"超出免费额度", 250000, 200000, 50000},
		{"没有配置每日额度", 250000, 0, 250000},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := chargeableTokens(test.used, test.limit); got != test.want {
				t.Fatalf("chargeableTokens(%d, %d) = %d，应为 %d",
					test.used, test.limit, got, test.want)
			}
		})
	}
}

// fakeRecorder 实现 nowpay.Recorder：只记下余额刷新请求，核销入口不做别的事。
type fakeRecorder struct {
	perPoint  int64
	refreshed []string
}

func (f *fakeRecorder) Record(context.Context, string, string, int64) {}

func (f *fakeRecorder) Resume(context.Context, string) {}

func (f *fakeRecorder) RefreshBalance(_ context.Context, userID string) {
	f.refreshed = append(f.refreshed, userID)
}

func (f *fakeRecorder) TokensPerPoint() int64 { return f.perPoint }

// TestPostgresReserveAllowsPointsBeyondTheFreeAllowance 守住付费用户能不能用：免费
// 额度用完之前不读余额，用完之后按本地副本放行，副本缺失时这次仍回 429 并排一次
// 异步查询（ADR-0069）。
func TestPostgresReserveAllowsPointsBeyondTheFreeAllowance(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	// 一个积分一千个计费 token，聊天与嵌入的免费额度各 100 个 token。
	recorder := &fakeRecorder{perPoint: 1000}
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 100, 0)

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("免费额度内的预留应为 100，得到 %d %v", got, err)
	}
	// 免费额度用完且还没有余额副本：这一轮回 429，同时排一次余额查询。
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 50); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("没有余额副本时免费额度之外应拒绝，得到 %v", err)
	}
	if len(recorder.refreshed) != 1 || recorder.refreshed[0] != "u1" {
		t.Fatalf("副本缺失时应排一次余额查询: %+v", recorder.refreshed)
	}
	// 写入 5 个积分之后，免费额度之外按 5,000 个 token 放行。
	if err := st.SaveBalance(ctx, "u1", 5); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3000); err != nil || got != 3000 {
		t.Fatalf("有余额时免费额度之外应放行 3,000，得到 %d %v", got, err)
	}
	if len(recorder.refreshed) != 1 {
		t.Fatalf("副本新鲜时不应再排查询: %+v", recorder.refreshed)
	}
	// 嵌入不能用积分支付：免费额度用完之后仍然拒绝。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindEmbedding, "", 100); err != nil || got != 100 {
		t.Fatalf("嵌入免费额度内的预留应为 100，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindEmbedding, "", 10); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("嵌入不应按积分放行，得到 %v", err)
	}
}

// TestPostgresReserveCountsChargesAndUnbilledTokens 守住两处扣减：副本同步之后写入
// 的核销流水、当天已经发生但还没有记进流水的计费量，都会让可放行的量变小，同一笔
// 用量不会因为预留与核销的先后被放行两次。
func TestPostgresReserveCountsChargesAndUnbilledTokens(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	st.SetQuotaLimits(100, 0, 0)

	if err := st.SaveBalance(ctx, "u1", 5); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3100); err != nil || got != 3100 {
		t.Fatalf("五积分的余额应放行 3,100 个 token，得到 %d %v", got, err)
	}
	// 副本同步之后记了一笔 2 个积分、2,000 个计费 token 的流水；已用 3,100 与免费
	// 额度 100 之间还有 1,000 个 token 没有记进流水。
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: day, Tokens: 2000,
	}, 2)
	if err != nil || !ok || charge.Points != 2 {
		t.Fatalf("应写入一笔两积分的流水: %+v %v %v", charge, ok, err)
	}
	// 可用积分 5-2=3 折 3,000 个 token，再减去未记流水的 1,000 个，于是只能再放行 2,000。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 5000); err != nil || got != 2000 {
		t.Fatalf("核销与未记账用量都应从可放行量里扣掉，得到 %d %v", got, err)
	}
}

// TestPostgresReserveRefreshesAStaleBalanceCopy 守住副本过期时的处理：这一轮仍按旧
// 值放行，同时排一次异步查询，请求路径上不调用即刻收。
func TestPostgresReserveRefreshesAStaleBalanceCopy(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	recorder := &fakeRecorder{perPoint: 1000}
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0, 0)
	if err := st.SaveBalance(ctx, "u1", 2); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, err := st.pool.Exec(ctx,
		`UPDATE nowpay_balance SET synced_at = now() - interval '1 hour' WHERE user_id = $1`, "u1"); err != nil {
		t.Fatalf("backdate balance: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 1500); err != nil || got != 1500 {
		t.Fatalf("过期副本仍按旧值放行，得到 %d %v", got, err)
	}
	if len(recorder.refreshed) != 1 || recorder.refreshed[0] != "u1" {
		t.Fatalf("副本过期时应排一次余额查询: %+v", recorder.refreshed)
	}
}

// TestPostgresSaveBalanceClampsNegative 守住副本不会是负数：核销结果与查询接口都
// 可能传来零，负数一律按零落库。
func TestPostgresSaveBalanceClampsNegative(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	if err := st.SaveBalance(ctx, "u1", -3); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	row, err := st.q.BalanceForReserve(ctx, "u1")
	if err != nil {
		t.Fatalf("read balance: %v", err)
	}
	if row.RemainingPoints != 0 {
		t.Fatalf("副本不应是负数，得到 %d", row.RemainingPoints)
	}
}
