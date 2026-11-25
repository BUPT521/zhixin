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

// fakeRecorder 实现 nowpay.Recorder：记下余额刷新请求与核销申请，其余不做别的事。
type fakeRecorder struct {
	perPoint  int64
	refreshed []string
	charged   []int64
}

func (f *fakeRecorder) Record(_ context.Context, _, _ string, chargeable int64) {
	f.charged = append(f.charged, chargeable)
}

func (f *fakeRecorder) Resume(context.Context, string) {}

func (f *fakeRecorder) RefreshBalance(_ context.Context, userID string) {
	f.refreshed = append(f.refreshed, userID)
}

func (f *fakeRecorder) TokensPerPoint() int64 { return f.perPoint }

// enablePaidQuota 像启动时那样确认即刻收的表都在，打开免费额度之外的放行。
func enablePaidQuota(t *testing.T, st *Store) {
	t.Helper()
	if err := st.CheckNowPaySchema(context.Background()); err != nil {
		t.Fatalf("check nowpay schema: %v", err)
	}
}

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
	enablePaidQuota(t, st)
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
	enablePaidQuota(t, st)
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
	// 可用积分 5-2=3 折 3,000 个 token，再减去未记流水的 1,000 个，于是只能再放行
	// 2,000；超出这个数的请求整单拒绝，原因是有积分但不够。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 2000); err != nil || got != 2000 {
		t.Fatalf("核销与未记账用量都应从可放行量里扣掉，得到 %d %v", got, err)
	}
	var quota *llmproxy.QuotaExceededError
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 2001); !errors.As(err, &quota) || quota.Reason != llmproxy.QuotaReasonPoints {
		t.Fatalf("可用积分不够时应返回 points，得到 %v", err)
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
	enablePaidQuota(t, st)
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

// TestPostgresChargePayUsesSettledUsageOnly 守住 3.1：另一个请求还在途时结算这一笔，
// 核销只能按已结算的用量算，不能把在途预留也算成已经产生的费用，否则并发时多扣
// 积分（ADR-0071）。
func TestPostgresChargePayUsesSettledUsageOnly(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0, 0)
	if err := st.SaveBalance(ctx, "u1", 10); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	// 两个请求同时在途：A 预留 400，B 预留 2,000。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 400); err != nil || got != 400 {
		t.Fatalf("A 应预留 400，得到 %d %v", got, err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 2000); err != nil || got != 2000 {
		t.Fatalf("B 应预留 2,000，得到 %d %v", got, err)
	}
	// B 实际用了 1,500：当天已结算 1,500，另有一笔 400 还在途。
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 2000, 1500, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if len(recorder.charged) != 1 {
		t.Fatalf("结算之后应申请一次核销，实际 %d 次", len(recorder.charged))
	}
	// 免费额度 100，所以应当按 1,500-100=1,400 申请；把在途的 400 算进去会是 1,800。
	if recorder.charged[0] != 1400 {
		t.Fatalf("核销应按已结算用量算 1,400，得到 %d", recorder.charged[0])
	}
}

// TestPostgresPointsView 守住账号页的两个积分数字：当天已核销成功的积分，与余额
// 副本里还可以使用的积分；没有开通收款时两个数都不给。
func TestPostgresPointsView(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	// 没有配置即刻收时不返回积分。
	points, err := st.Points(ctx, "u1", day)
	if err != nil || points.Known {
		t.Fatalf("未开通收款时不应返回积分: %+v %v", points, err)
	}

	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	if err := st.SaveBalance(ctx, "u1", 5); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	// 副本同步之后有两笔核销：一笔确认成功，一笔还在处理。
	for _, charge := range []struct {
		id, status string
		points     int64
		tokens     int64
	}{
		{"nc_1", nowpay.StatusSucceeded, 2, 2000},
		{"nc_2", nowpay.StatusPending, 1, 1000},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status)
			 VALUES ($1, 'u1', $2::date, $3, $4, $5)`,
			charge.id, day, charge.points, charge.tokens, charge.status); err != nil {
			t.Fatalf("insert charge: %v", err)
		}
	}
	points, err = st.Points(ctx, "u1", day)
	if err != nil {
		t.Fatalf("points: %v", err)
	}
	if !points.Known || points.Charged != 2 {
		t.Fatalf("当天已核销应为 2 个积分: %+v", points)
	}
	// 5 个积分减去还在途的 1 个；已经成功的那 2 个也在副本同步之后，一并扣掉。
	if points.Remaining != 2 {
		t.Fatalf("剩余积分应为 2，得到 %+v", points)
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
	enablePaidQuota(t, st)
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

// TestPostgresStartsWithoutTheBalanceTable 守住建表顺序：余额副本是纯新增表，还没
// 建好时服务照常启动，免费额度之外的放行停用，读写副本都静默跳过（ADR-0069）。
func TestPostgresStartsWithoutTheBalanceTable(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `DROP TABLE nowpay_balance`); err != nil {
		t.Fatalf("drop nowpay_balance: %v", err)
	}
	if err := st.CheckNowPaySchema(ctx); err != nil {
		t.Fatalf("缺余额副本时启动不应失败: %v", err)
	}
	const day = "2026-11-25"
	recorder := &fakeRecorder{perPoint: 1000}
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0, 0)
	if err := st.SaveBalance(ctx, "u1", 5); err != nil {
		t.Fatalf("缺表时写副本应跳过而不是报错: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("免费额度内的预留不受影响，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 50); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("缺副本表时免费额度之外仍应拒绝，得到 %v", err)
	}
	if len(recorder.refreshed) != 0 {
		t.Fatalf("缺表时不应排余额查询: %+v", recorder.refreshed)
	}
}
