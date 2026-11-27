package pg

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

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

func TestPostgresDailyChargeReconciliation(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	st.dailyTokens = 10000
	if _, err := st.pool.Exec(ctx, `
INSERT INTO app_user (id, password_hash) VALUES ('u1', 'hash'), ('u2', 'hash');
INSERT INTO llm_quota (user_id, daily_tokens) VALUES ('u1', 5000);
INSERT INTO llm_usage (user_id, day, kind, api_key_id, tokens, reserved_tokens, embedding_billed_tokens) VALUES
  ('u1', '2026-11-26', 'chat', '', 13000, 900000, 0),
  ('u1', '2026-11-26', 'embedding', 'key-a', 3000, 0, 7500),
  ('u1', '2026-11-27', 'chat', '', 100000, 0, 0),
  ('u2', '2026-11-26', 'chat', '', 40001, 0, 0);
INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status) VALUES
  ('nc_success', 'u1', '2026-11-26', 2, 20000, 'succeeded'),
  ('nc_pending', 'u1', '2026-11-26', 1, 20000, 'pending'),
  ('nc_processing', 'u1', '2026-11-26', 1, 20000, 'processing'),
  ('nc_abandoned', 'u1', '2026-11-26', 1, 20000, 'abandoned'),
  ('nc_failed', 'u1', '2026-11-26', 8, 20000, 'failed'),
  ('nc_other_day', 'u1', '2026-11-27', 10, 20000, 'succeeded');`); err != nil {
		t.Fatal(err)
	}
	want := []nowpay.AccountCharges{
		{UserID: "u1", ChargeableTokens: 15500, Applied: 5, Charged: 2},
		{UserID: "u2", ChargeableTokens: 30001},
	}
	got, err := st.DailyChargeReconciliation(ctx, "2026-11-26")
	if err != nil || !slices.Equal(got, want) {
		t.Fatalf("账号对账 = %+v, %v，应为 %+v", got, err, want)
	}
	st.dailyTokens = 0
	got, err = st.DailyChargeReconciliation(ctx, "2026-11-26")
	if err != nil || !slices.Equal(got, want[:1]) {
		t.Fatalf("默认额度不限时只核对设置了覆盖值的账号，得到 %+v, %v", got, err)
	}
}

// fakeRecorder 实现 nowpay.Recorder：记下余额刷新请求与核销申请，其余不做别的事。
type fakeRecorder struct {
	perPoint  int64
	refreshed []string
	charged   []int64
	// chargedDays 与 charged 一一对应，记下每次申请记在哪一天。
	chargedDays []string
	// drop 为真时 Record 什么也不做，模拟进程在结算之后、申请核销之前退出。
	drop bool
	// queried 记下管理后台“刷新余额”同步查询过的账号；queryErr 模拟即刻收不可用。
	queried  []string
	queryErr error
	// coalesced 为真时 RefreshBalance 报告这次没有入队，模拟一分钟合并窗口里的
	// 重复请求。
	coalesced bool
}

func (f *fakeRecorder) Record(_ context.Context, _, day string, chargeable int64) {
	if f.drop {
		return
	}
	f.charged = append(f.charged, chargeable)
	f.chargedDays = append(f.chargedDays, day)
}

func (f *fakeRecorder) Resume(context.Context, string) {}

func (f *fakeRecorder) RefreshBalance(_ context.Context, userID string) bool {
	f.refreshed = append(f.refreshed, userID)
	return !f.coalesced
}

// QueryBalance 让管理后台的“刷新余额”在这个假执行器上也能通过：它记下被同步查询
// 的账号，余额副本由测试自己写。
func (f *fakeRecorder) QueryBalance(_ context.Context, userID string) error {
	f.queried = append(f.queried, userID)
	return f.queryErr
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
	// 一个积分一千个计费 token，聊天与嵌入共用 100 个免费计费 token。
	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0)

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
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3000); err != nil || got != 3000 {
		t.Fatalf("有余额时免费额度之外应放行 3,000，得到 %d %v", got, err)
	}
	if len(recorder.refreshed) != 1 {
		t.Fatalf("副本新鲜时不应再排查询: %+v", recorder.refreshed)
	}
	// 嵌入与聊天共用剩下的 2,000 个付费 token，外部余额不会按用途重复计算。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindEmbedding, "", 2000); err != nil || got != 2000 {
		t.Fatalf("嵌入应能预留剩余付费额度，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("两种用途已预留全部余额，应拒绝额外请求：%v", err)
	}
	// 历史嵌入用量与预留保留，但不能进入共享核销。
	if _, err := st.pool.Exec(ctx, "UPDATE llm_usage SET tokens = 2000000, reserved_tokens = 2000 WHERE user_id = 'u1' AND kind = 'embedding'"); err != nil {
		t.Fatal(err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindEmbedding, "", 2000, 1100, llmproxy.Usage{Input: 5500}, llmproxy.SettleAttempt{Attempts: 1}); err != nil {
		t.Fatal(err)
	}
	if len(recorder.charged) != 1 || recorder.charged[0] != 1000 {
		t.Fatalf("核销只按已结算的超额 1,000 个 token 计算：%+v", recorder.charged)
	}
	if used, err := st.Used(ctx, "u1", day, ""); err != nil || used != 1100 {
		t.Fatalf("共享已结算用量 = %d, %v", used, err)
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
	st.SetQuotaLimits(100, 0)

	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3100); err != nil || got != 3100 {
		t.Fatalf("五积分的余额应放行 3,100 个 token，得到 %d %v", got, err)
	}
	// 副本同步之后记了一笔 2 个积分、2,000 个计费 token 的流水；已用 3,100 与免费
	// 额度 100 之间还有 1,000 个 token 没有记进流水。
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: day, Tokens: 2000,
	})
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
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 2, time.Now()); err != nil {
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
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 10, time.Now()); err != nil {
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
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 2000, 1500, llmproxy.Usage{}, llmproxy.SettleAttempt{Attempts: 1}); err != nil {
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
	// 没有配置即刻收时两个数都不返回。
	points, err := st.Points(ctx, "u1", day)
	if err != nil || points.ChargedKnown || points.RemainingKnown {
		t.Fatalf("未开通收款时不应返回积分: %+v %v", points, err)
	}

	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
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
	if !points.ChargedKnown || !points.RemainingKnown || points.Charged != 2 {
		t.Fatalf("当天已核销应为 2 个积分: %+v", points)
	}
	// 5 个积分减去还在途的 1 个；已经成功的那 2 个也在副本同步之后，一并扣掉。
	if points.Remaining != 2 {
		t.Fatalf("剩余积分应为 2，得到 %+v", points)
	}
}

// TestPostgresPointsAdminView 守住管理后台的积分只读视图：最近流水按时间倒序、
// 余额副本带出快照时刻，以及“刷新余额”确实同步查询了一次即刻收；查询失败原样
// 返回，副本不动。
func TestPostgresPointsAdminView(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	// 没有配置即刻收时没有流水，也没有余额可查。
	if charges, err := st.PointCharges(ctx, "u1", 5); err != nil || len(charges) != 0 {
		t.Fatalf("未开通收款时不应有流水: %+v %v", charges, err)
	}
	if enabled, err := st.RefreshPoints(ctx, "u1"); err != nil || enabled {
		t.Fatalf("未开通收款时不应查询余额: %v %v", enabled, err)
	}

	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	for i, charge := range []struct {
		id, status string
		points     int64
		tokens     int64
	}{
		{"nc_1", nowpay.StatusSucceeded, 2, 2000},
		{"nc_2", nowpay.StatusFailed, 1, 1000},
		{"nc_3", nowpay.StatusPending, 3, 3000},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, updated_at)
			 VALUES ($1, 'u1', $2::date, $3, $4, $5, now() - make_interval(mins => $6::int), now() - make_interval(mins => $6::int))`,
			charge.id, day, charge.points, charge.tokens, charge.status, 10-i); err != nil {
			t.Fatalf("insert charge: %v", err)
		}
	}
	charges, err := st.PointCharges(ctx, "u1", 2)
	if err != nil {
		t.Fatalf("charges: %v", err)
	}
	if len(charges) != 2 || charges[0].ID != "nc_3" || charges[1].ID != "nc_2" {
		t.Fatalf("最近两条流水应新到旧: %+v", charges)
	}
	if charges[0].Points != 3 || charges[0].BilledTokens != 3000 || charges[0].Status != nowpay.StatusPending ||
		charges[0].Day.Format("2006-01-02") != day {
		t.Fatalf("流水字段: %+v", charges[0])
	}

	synced := time.Now().Add(-30 * time.Second)
	if err := st.SaveBalance(ctx, "u1", 7, synced); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	points, err := st.Points(ctx, "u1", day)
	if err != nil {
		t.Fatalf("points: %v", err)
	}
	// 可用积分是副本 7 减去没有反映的核销：待支付的 3 分还没有确认扣减，一律
	// 计入；已成功的 2 分在快照之前就确认了，副本里已经反映，不再重复扣，因此
	// 是 4（ADR-0073）。
	if !points.RemainingKnown || points.Remaining != 4 || points.SyncedAt.IsZero() {
		t.Fatalf("副本与快照时刻: %+v", points)
	}

	if enabled, err := st.RefreshPoints(ctx, "u1"); err != nil || !enabled {
		t.Fatalf("刷新余额: %v %v", enabled, err)
	}
	if len(recorder.queried) != 1 || recorder.queried[0] != "u1" {
		t.Fatalf("刷新余额应同步查询一次: %+v", recorder.queried)
	}
	recorder.queryErr = errors.New("gateway down")
	if enabled, err := st.RefreshPoints(ctx, "u1"); !enabled || err == nil {
		t.Fatalf("查询失败应原样返回: %v %v", enabled, err)
	}
}

// TestPostgresPointsMatchTheAmountThatCanBeReleased 守住账号页的剩余积分与放行
// 同口径：有在途预留时页面显示的数就是还能放行的积分。免费额度一百、副本五积分
// （一个积分一千 token），当天已结算一百、另有一笔三千 token 在途，可用积分因此是
// 5-3=2，放行侧也只还能放行 2,000 个 token（ADR-0073）。
func TestPostgresPointsMatchTheAmountThatCanBeReleased(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	// 先把免费的一百 token 用完。
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); err != nil {
		t.Fatalf("reserve the free quota: %v", err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 100, 100, llmproxy.Usage{}, llmproxy.SettleAttempt{Attempts: 1}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	// 再发起一笔三千 token 的请求，它还留在途里没有结算。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3000); err != nil || got != 3000 {
		t.Fatalf("reserve from the points: %d %v", got, err)
	}
	points, err := st.Points(ctx, "u1", day)
	if err != nil {
		t.Fatalf("points: %v", err)
	}
	if !points.RemainingKnown || points.Remaining != 2 {
		t.Fatalf("在途的三千 token 应占三个积分，剩余应为 2: %+v", points)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 2000); err != nil || got != 2000 {
		t.Fatalf("与页面一致，应还能放行 2,000 个 token: %d %v", got, err)
	}
	var quota *llmproxy.QuotaExceededError
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 1); !errors.As(err, &quota) || quota.Reason != llmproxy.QuotaReasonPoints {
		t.Fatalf("页面显示的积分放行完之后应回 points，得到 %v", err)
	}
}

func TestPostgresPointsAccountForPartialReservationsAndCappedCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 1, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 500); err != nil || got != 500 {
		t.Fatalf("应预留免费额度 100 和付费额度 400，得到 %d %v", got, err)
	}
	points, err := st.Points(ctx, "u1", day)
	if err != nil || !points.RemainingKnown || points.Remaining != 0 {
		t.Fatalf("部分占用的积分不能再作为整积分展示: %+v %v", points, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 601); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("只能再放行 600 个计费 token，得到 %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 600); err != nil || got != 600 {
		t.Fatalf("积分覆盖的余量应可以用完，得到 %d %v", got, err)
	}

	// 结算用量包含一次超出预留的实际用量。余额一分，流水的累计用量仍是 2,400。
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 1100, 2500, llmproxy.Usage{}, llmproxy.SettleAttempt{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{ID: "nc_capped", UserID: "u1", Day: day, Tokens: 2400})
	if err != nil || !ok || charge.Points != 1 {
		t.Fatalf("核销应受余额限制: %+v %v %v", charge, ok, err)
	}
	confirmedAt, err := st.SetStatus(ctx, charge.ID, nowpay.StatusSucceeded, "")
	if err != nil {
		t.Fatalf("confirm charge: %v", err)
	}
	if err := st.SaveBalance(ctx, "u1", 2, confirmedAt); err != nil {
		t.Fatalf("save replenished balance: %v", err)
	}
	points, err = st.Points(ctx, "u1", day)
	if err != nil || points.Charged != 1 || !points.RemainingKnown || points.Remaining != 0 {
		t.Fatalf("两分余额已被未覆盖的 1,400 个计费 token 部分占用: %+v %v", points, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 601); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("截断的流水只覆盖实际申请的一分，得到 %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 600); err != nil || got != 600 {
		t.Fatalf("补充余额后应能预留 600 个计费 token，得到 %d %v", got, err)
	}
}

// TestPostgresPointsKeepTheChargedTotalWithoutABalanceCopy 守住副本缺失时已核销积分
// 照常返回：契约里 charged_points 只在没有开通收款时为 null，账号还没有副本时不该
// 把已经扣掉的积分一起藏掉（ADR-0071）。
func TestPostgresPointsKeepTheChargedTotalWithoutABalanceCopy(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status)
		 VALUES ('nc_1', 'u1', $1::date, 2, 2000, 'succeeded')`, day); err != nil {
		t.Fatalf("insert charge: %v", err)
	}
	points, err := st.Points(ctx, "u1", day)
	if err != nil {
		t.Fatalf("points: %v", err)
	}
	if !points.ChargedKnown || points.Charged != 2 {
		t.Fatalf("没有副本时已核销的两个积分仍应返回: %+v", points)
	}
	if points.RemainingKnown {
		t.Fatalf("没有副本时不应给出剩余积分: %+v", points)
	}
}

// TestPostgresUnsettledGlobalSkipsChargesWithoutAnOwner 守住全局补查不取删号之后
// 失去归属的流水：即刻收的补查要带买家标识，user_id 为空的行永远补不到结果，留在
// 这一批里还会把更晚的流水挤出去。
func TestPostgresUnsettledGlobalSkipsChargesWithoutAnOwner(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at)
		 VALUES ('nc_owner', 'u1', current_date, 1, 1000, 'pending', now() - interval '1 hour'),
		        ('nc_orphan', NULL, current_date, 1, 1000, 'pending', now() - interval '1 hour')`); err != nil {
		t.Fatalf("insert charges: %v", err)
	}
	charges, err := st.UnsettledGlobal(ctx, time.Now().Add(-5*time.Minute), 50)
	if err != nil {
		t.Fatalf("unsettled: %v", err)
	}
	if len(charges) != 1 || charges[0].ID != "nc_owner" {
		t.Fatalf("只应取有归属的流水: %+v", charges)
	}
}

// TestPostgresDeleteOrphanCharges 守住失去归属的流水按保留期清理：只删创建时间早于
// 保留期、又没有结论的那几行，有归属的流水与还没有到期的行都留下。
func TestPostgresDeleteOrphanCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at)
		 VALUES ('nc_orphan_old', NULL, current_date, 1, 1000, 'pending', now() - interval '200 days'),
		        ('nc_orphan_new', NULL, current_date, 1, 1000, 'pending', now() - interval '10 days'),
		        ('nc_orphan_done', NULL, current_date, 1, 1000, 'succeeded', now() - interval '200 days'),
		        ('nc_owner_old', 'u1', current_date, 1, 1000, 'pending', now() - interval '200 days')`); err != nil {
		t.Fatalf("insert charges: %v", err)
	}
	deleted, err := st.DeleteOrphanCharges(ctx, time.Now().AddDate(0, 0, -180), 1000)
	if err != nil || deleted != 1 {
		t.Fatalf("应只删掉一条失去归属又没有结论的旧流水: %d %v", deleted, err)
	}
	var left int64
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM nowpay_charge WHERE id = 'nc_orphan_old'`).Scan(&left); err != nil {
		t.Fatalf("count: %v", err)
	}
	if left != 0 {
		t.Fatalf("失去归属的旧流水应已删除，剩下 %d 行", left)
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
	if err := st.SaveBalance(ctx, "u1", -3, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	var remaining int64
	if err := st.pool.QueryRow(ctx, `SELECT remaining_points FROM nowpay_balance WHERE user_id = 'u1'`).Scan(&remaining); err != nil {
		t.Fatalf("read balance: %v", err)
	}
	if remaining != 0 {
		t.Fatalf("副本不应是负数，得到 %d", remaining)
	}
}

// TestPostgresReservePointsCapsAtTheBalanceCopy 守住核销侧按可用积分收口：副本五
// 积分、应扣二十积分时只写五积分；同一天再申请时副本已经被这笔流水占满，不再写
// 新流水（ADR-0073）。
func TestPostgresReservePointsCapsAtTheBalanceCopy(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	})
	if err != nil || !ok || charge.Points != 5 {
		t.Fatalf("应只申请副本里的五积分: %+v %v %v", charge, ok, err)
	}
	if _, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_2", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	}); err != nil || ok {
		t.Fatalf("副本已被占满时不该再写流水: %v %v", ok, err)
	}
}

func TestPostgresReservePointsSharesTheBalanceAcrossDays(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	if err := st.SaveBalance(ctx, "u1", 1, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	type result struct {
		points int64
		err    error
	}
	results := make(chan result, 2)
	for _, day := range []string{"2026-11-25", "2026-11-26"} {
		go func() {
			charge, _, err := st.ReservePoints(ctx, nowpay.Charge{ID: "nc_" + day, UserID: "u1", Day: day, Tokens: 1000})
			results <- result{points: charge.Points, err: err}
		}()
	}
	first, second := <-results, <-results
	if total := first.points + second.points; first.err != nil || second.err != nil || total != 1 {
		t.Fatalf("跨日并发核销合计只能申请余额中的一分，得到 %d %v %v", total, first.err, second.err)
	}
}

// TestPostgresReservePointsSubtractsUnreflectedCharges 守住副本之外还没有反映的核销
// 也占着余额：副本五积分、两积分待确认时，当天合计最多申请五积分，这次补三积分
// （ADR-0073）。
func TestPostgresReservePointsSubtractsUnreflectedCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status)
		 VALUES ('nc_old', 'u1', '2026-11-25'::date, 2, 20000, 'pending')`); err != nil {
		t.Fatalf("insert charge: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	})
	if err != nil || !ok || charge.Points != 3 {
		t.Fatalf("当天合计应只申请五积分，这次补三积分: %+v %v %v", charge, ok, err)
	}
}

// TestPostgresReservePointsKeepsApplyingAfterTheDayTotalExceedsTheCopy 守住收口只截
// 差额：当天已经申请的四积分还在待确认、副本五积分时，可用积分只剩一积分，应扣十
// 积分仍然要申请这一积分。把已经申请的量从可用积分里再减一次时，这里会因为
// “已申请四积分不小于可用一积分”直接跳过，当天剩下的积分白白放行（ADR-0073）。
func TestPostgresReservePointsKeepsApplyingAfterTheDayTotalExceedsTheCopy(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status)
		 VALUES ('nc_old', 'u1', '2026-11-25'::date, 4, 40000, 'pending')`); err != nil {
		t.Fatalf("insert charge: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 100000,
	})
	if err != nil || !ok || charge.Points != 1 {
		t.Fatalf("可用积分只剩一积分时应再申请一积分: %+v %v %v", charge, ok, err)
	}
	var total int64
	if err := st.pool.QueryRow(ctx,
		`SELECT COALESCE(sum(points), 0) FROM nowpay_charge WHERE user_id = 'u1'`).Scan(&total); err != nil {
		t.Fatalf("count: %v", err)
	}
	if total != 5 {
		t.Fatalf("当天合计应与副本的五积分相等，得到 %d", total)
	}
}

// TestChargeDeltaCapsTheDifference 守住收口公式：先算当天还没有申请的差额，再按可用
// 积分截断这个差额，可用积分为负表示副本未知、整额申请差额。公式单独可测，因为
// PostgreSQL 用例在没有测试库的机器上会跳过，收口这里不能再没有用例（ADR-0073）。
func TestChargeDeltaCapsTheDifference(t *testing.T) {
	cases := []struct {
		name                         string
		required, applied, available int64
		want                         int64
	}{
		{"副本小于应扣时只申请副本", 20, 0, 5, 5},
		{"待确认的核销占用可用积分", 20, 2, 3, 3},
		{"已申请超过可用积分时仍申请剩余差额", 10, 4, 1, 1},
		{"成功并已反映的核销不再从可用积分里减", 150, 40, 100, 100},
		{"可用积分为零时不申请", 20, 5, 0, 0},
		{"副本未知时只申请差额", 150, 40, -1, 110},
		{"当天已经申请够时不申请", 20, 20, 5, 0},
		{"已申请超过应扣时不申请", 20, 25, 5, 0},
	}
	for _, c := range cases {
		if got := pointBudgetFor(c.required*1000, c.applied, c.available, 1000).Due; got != c.want {
			t.Errorf("%s: 应申请 %d，得到 %d", c.name, c.want, got)
		}
	}
}

// TestPostgresReservePointsCapsTheDifferenceNotTheDayTotal 守住已经成功、已经反映在
// 副本里的核销不会被从可用积分里再减一次：副本一百积分、当天已有四十积分核销成功，
// 应扣一百五十积分时这次应申请一百积分（当天合计一百四十），而不是把四十从一百里
// 减掉、只申请六十积分（ADR-0073）。
func TestPostgresReservePointsCapsTheDifferenceNotTheDayTotal(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	// 这笔核销在副本的快照之前已经成功，副本里的一百积分是扣过它之后的值。
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, updated_at)
		 VALUES ('nc_old', 'u1', '2026-11-25'::date, 40, 400000, 'succeeded',
		         now() - interval '10 minutes', now() - interval '10 minutes')`); err != nil {
		t.Fatalf("insert charge: %v", err)
	}
	if err := st.SaveBalance(ctx, "u1", 100, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 1500000,
	})
	if err != nil || !ok || charge.Points != 100 {
		t.Fatalf("应只按副本剩余的一百积分收口: %+v %v %v", charge, ok, err)
	}
}

// TestPostgresReservePointsWithoutBalanceCopyChargesInFull 守住读不到副本时不截断：
// 没有副本行或余额表未就绪时按尚未申请的差额核销。
func TestPostgresReservePointsWithoutBalanceCopyChargesInFull(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	})
	if err != nil || !ok || charge.Points != 20 {
		t.Fatalf("没有副本时应整额申请二十积分: %+v %v %v", charge, ok, err)
	}
}

// TestPostgresReservePointsZeroCopyWritesNothing 守住副本为零时的跳过：不写流水，
// 也不留下一个注定失败的核销（ADR-0073）。
func TestPostgresReservePointsZeroCopyWritesNothing(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	st.SetNowPay(&fakeRecorder{perPoint: 1000})
	if err := st.SaveBalance(ctx, "u1", 0, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	}); err != nil || ok {
		t.Fatalf("副本为零时不该写流水: %v %v", ok, err)
	}
	var count int64
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM nowpay_charge WHERE user_id = 'u1'`).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 0 {
		t.Fatalf("副本为零时不该留下流水，实际 %d 条", count)
	}
}

// TestPostgresConcurrentReserveAndSettleKeepTheInstanceLedger 守住实例账在并发下
// 不会变成负数，也不会超过预算（ADR-0070 的免费段）。
func TestPostgresConcurrentReserveAndSettleKeepTheInstanceLedger(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	st.SetQuotaLimits(1_000_000, 1000)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 150); err != nil {
				return
			}
			_ = st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 150, 150, llmproxy.Usage{Input: 150}, llmproxy.SettleAttempt{Attempts: 1})
		}()
	}
	wg.Wait()
	used, err := st.InstanceUsed(ctx, day)
	if err != nil {
		t.Fatalf("instance used: %v", err)
	}
	if used < 0 || used > 1000 {
		t.Fatalf("实例账应在 0 到预算之间，得到 %d", used)
	}
}

// 缺少余额副本表时不能启用收款，未启用收款的实例仍可使用免费额度。
func TestPostgresRequiresBalanceTableForPaidQuota(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `DROP TABLE nowpay_balance`); err != nil {
		t.Fatalf("drop nowpay_balance: %v", err)
	}
	if err := st.CheckNowPaySchema(ctx); err == nil || !strings.Contains(err.Error(), "nowpay_balance") {
		t.Fatalf("启用收款时缺余额副本表应拒绝启动: %v", err)
	}
	const day = "2026-11-25"
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("缺表时写副本应跳过而不是报错: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("免费额度内的预留不受影响，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 50); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("缺副本表时免费额度之外仍应拒绝，得到 %v", err)
	}
}

// TestPostgresReserveReportsSyncingWhileTheCopyIsMissing 守住副本缺失时的原因：刷新
// 刚刚入队，这一轮说不准是不是真的不够，回 syncing 而不是让客户端去购买（ADR-0073）。
func TestPostgresReserveReportsSyncingWhileTheCopyIsMissing(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0)

	var quota *llmproxy.QuotaExceededError
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 150); !errors.As(err, &quota) ||
		quota.Reason != llmproxy.QuotaReasonSyncing {
		t.Fatalf("副本缺失且刷新入队时应回 syncing，得到 %v", err)
	}
	// 一分钟内的第二次请求没有再入队；客户端已经收到过 syncing，这一次按没有积分回
	// account，不能永远停在“正在同步”。
	recorder.coalesced = true
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 150); !errors.As(err, &quota) ||
		quota.Reason != llmproxy.QuotaReasonAccount {
		t.Fatalf("刷新没有入队时应回 account，得到 %v", err)
	}
}

// TestPostgresReserveReportsSyncingForAStaleCopy 守住过期副本的处理：副本超过一分钟
// 没有同步时先排刷新并回 syncing，副本新鲜却不够时才回 points（ADR-0073）。
func TestPostgresReserveReportsSyncingForAStaleCopy(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	recorder := &fakeRecorder{perPoint: 1000}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 1, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, err := st.pool.Exec(ctx,
		`UPDATE nowpay_balance SET synced_at = now() - interval '1 hour' WHERE user_id = $1`, "u1"); err != nil {
		t.Fatalf("backdate balance: %v", err)
	}
	var quota *llmproxy.QuotaExceededError
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3000); !errors.As(err, &quota) ||
		quota.Reason != llmproxy.QuotaReasonSyncing {
		t.Fatalf("过期副本且刷新入队时应回 syncing，得到 %v", err)
	}
	// 副本换成新快照之后仍然不够：这一轮是明确的积分不足。
	if err := st.SaveBalance(ctx, "u1", 1, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 3000); !errors.As(err, &quota) ||
		quota.Reason != llmproxy.QuotaReasonPoints {
		t.Fatalf("副本新鲜但积分不够时应回 points，得到 %v", err)
	}
}

// TestPostgresSaveBalanceKeepsTheNewerSnapshot 守住乱序响应：晚到的旧快照不能覆盖
// 新副本，新快照照常覆盖（ADR-0073）。
func TestPostgresSaveBalanceKeepsTheNewerSnapshot(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	base := time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)
	if err := st.SaveBalance(ctx, "u1", 5, base); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if err := st.SaveBalance(ctx, "u1", 2, base.Add(-time.Hour)); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	checkBalance := func(want int64, wantTime time.Time) {
		t.Helper()
		var remaining int64
		var syncedAt time.Time
		err := st.pool.QueryRow(ctx, `SELECT remaining_points, synced_at FROM nowpay_balance WHERE user_id = 'u1'`).Scan(&remaining, &syncedAt)
		if err != nil || remaining != want || !syncedAt.Equal(wantTime) {
			t.Fatalf("余额应为 %d、快照为 %v，得到 %d %v %v", want, wantTime, remaining, syncedAt, err)
		}
	}
	checkBalance(5, base)
	if err := st.SaveBalance(ctx, "u1", 7, base.Add(time.Minute)); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	checkBalance(7, base.Add(time.Minute))
}

// TestPostgresUnreflectedChargesFollowTheSnapshot 守住未反映流水的判断：pending 与
// processing 一律计入，succeeded 只在快照之后确认的计入，failed 不计（ADR-0073）。
func TestPostgresUnreflectedChargesFollowTheSnapshot(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	asOf := time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)
	if err := st.SaveBalance(ctx, "u1", 10, asOf); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	const day = "2026-11-25"
	for _, charge := range []struct {
		id      string
		day     string
		status  string
		points  int64
		created time.Time
		updated time.Time
	}{
		{"nc_pending_old", "2026-11-24", nowpay.StatusPending, 1, asOf.Add(-time.Hour), asOf.Add(-time.Hour)},
		{"nc_succeeded_new", day, nowpay.StatusSucceeded, 2, asOf.Add(-time.Hour), asOf.Add(time.Minute)},
		{"nc_succeeded_old", day, nowpay.StatusSucceeded, 4, asOf.Add(-2 * time.Hour), asOf.Add(-time.Hour)},
		{"nc_failed_new", day, nowpay.StatusFailed, 8, asOf.Add(-time.Hour), asOf.Add(time.Minute)},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, updated_at)
			 VALUES ($1, 'u1', $2::date, $3, $3, $4, $5, $6)`,
			charge.id, charge.day, charge.points, charge.status, charge.created, charge.updated); err != nil {
			t.Fatalf("insert charge: %v", err)
		}
	}
	date, err := pgDate(day)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := st.readPointLedger(ctx, st.q, "u1", date)
	if err != nil || ledger.balance != 10 || ledger.applied != 6 || ledger.charged != 6 ||
		ledger.unsettled != 1 || ledger.succeededAfterSync != 2 || ledger.available() != 7 {
		t.Fatalf("副本原值十积分，可用积分扣掉前一天待确认的一分与快照之后成功的两分后应为七积分，"+
			"当天只计成功的六积分: %+v %v", ledger, err)
	}
}

// TestPostgresPurchaseEntriesAreIdempotent 守住购买入口的存储口径：幂等键在账号内
// 唯一，只有 ready 且带链接、未过期的行才会被“继续上次购买”读到，失败或过期之后
// 整行替换成新的请求号（ADR-0074）。
func TestPostgresPurchaseEntriesAreIdempotent(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now()
	creating := nowpay.Purchase{
		OutRequestNo: "np_1", ClientRequestNo: "req-1", SKU: "S1",
		State: nowpay.PurchaseCreating, ExpiresAt: now.Add(15 * time.Minute),
	}
	err := st.LockPurchase(ctx, "u1", "req-1", func(ctx context.Context) error {
		return st.CreatePurchaseLink(ctx, "u1", creating)
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	got, ok, err := st.PurchaseByClientRequestNo(ctx, "u1", "req-1")
	if err != nil || !ok || got.OutRequestNo != "np_1" || got.State != nowpay.PurchaseCreating || got.URL != "" {
		t.Fatalf("应按幂等键读回 creating 行: %+v %v %v", got, ok, err)
	}
	// 同一键重复插入由唯一索引拒绝。
	if err := st.CreatePurchaseLink(ctx, "u1", nowpay.Purchase{
		OutRequestNo: "np_dup", ClientRequestNo: "req-1", SKU: "S1",
		State: nowpay.PurchaseCreating, ExpiresAt: now.Add(15 * time.Minute),
	}); err == nil {
		t.Fatal("同一账号同一幂等键不能插入第二行")
	}
	// 创单成功转 ready，之后“继续上次购买”能读到它。
	if err := st.ReadyPurchaseLink(ctx, "np_1", "alipays://x", now.Add(30*time.Minute)); err != nil {
		t.Fatalf("ready: %v", err)
	}
	latest, ok, err := st.LatestPurchaseLink(ctx, "u1", now)
	if err != nil || !ok || latest.OutRequestNo != "np_1" || latest.URL != "alipays://x" {
		t.Fatalf("应读到可用的购买入口: %+v %v %v", latest, ok, err)
	}
	// 链接过期之后不再算“可用”。
	if _, ok, err := st.LatestPurchaseLink(ctx, "u1", now.Add(31*time.Minute)); err != nil || ok {
		t.Fatalf("过期的入口不应被读到: %v %v", ok, err)
	}
	// 失败或过期之后换新请求号替换整行，回到 creating。
	if err := st.FailPurchaseLink(ctx, "np_1"); err != nil {
		t.Fatalf("fail: %v", err)
	}
	if _, ok, err := st.LatestPurchaseLink(ctx, "u1", now); err != nil || ok {
		t.Fatalf("failed 的入口不应被读到: %v %v", ok, err)
	}
	if err := st.ReplacePurchaseLink(ctx, "u1", nowpay.Purchase{
		OutRequestNo: "np_2", ClientRequestNo: "req-1", SKU: "S1",
		ExpiresAt: now.Add(15 * time.Minute),
	}); err != nil {
		t.Fatalf("replace: %v", err)
	}
	replaced, ok, err := st.PurchaseByClientRequestNo(ctx, "u1", "req-1")
	if err != nil || !ok || replaced.OutRequestNo != "np_2" || replaced.State != nowpay.PurchaseCreating || replaced.URL != "" {
		t.Fatalf("替换之后应回到 creating 并换请求号: %+v %v %v", replaced, ok, err)
	}
	var count int64
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM nowpay_purchase WHERE user_id = 'u1' AND client_request_no = 'req-1'`).Scan(&count); err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 1 {
		t.Fatalf("同一幂等键应只有一行，实际 %d 行", count)
	}
}

// TestPostgresRefusesToStartWithoutThePurchaseIdempotencyColumns 守住部署顺序：购买
// 入口缺幂等键的新列时启动直接失败，让自动部署回滚（ADR-0074）。
func TestPostgresRefusesToStartWithoutThePurchaseIdempotencyColumns(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	enablePaidQuota(t, st)
	if _, err := st.pool.Exec(ctx, `ALTER TABLE nowpay_purchase DROP COLUMN client_request_no`); err != nil {
		t.Fatalf("drop column: %v", err)
	}
	if err := st.CheckNowPaySchema(ctx); err == nil {
		t.Fatal("缺 client_request_no 列时启动应失败")
	}
}

// TestPostgresUnsettledGlobalOnlyTakesOldCharges 守住全局补查的范围：只取创建超过宽限
// 期、仍然 pending 或 processing 的流水，按上一次尝试时刻与创建时间升序，结果上限按
// 批次。
func TestPostgresUnsettledGlobalOnlyTakesOldCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now()
	for _, charge := range []struct {
		id      string
		status  string
		created time.Time
	}{
		{"nc_old_pending", nowpay.StatusPending, now.Add(-10 * time.Minute)},
		{"nc_old_processing", nowpay.StatusProcessing, now.Add(-8 * time.Minute)},
		{"nc_old_succeeded", nowpay.StatusSucceeded, now.Add(-9 * time.Minute)},
		{"nc_new_pending", nowpay.StatusPending, now.Add(-time.Minute)},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, updated_at)
			 VALUES ($1, 'u1', '2026-11-25'::date, 1, 10000, $2, $3, $3)`,
			charge.id, charge.status, charge.created); err != nil {
			t.Fatalf("insert charge: %v", err)
		}
	}
	charges, err := st.UnsettledGlobal(ctx, now.Add(-5*time.Minute), 50)
	if err != nil {
		t.Fatalf("unsettled global: %v", err)
	}
	if len(charges) != 2 {
		t.Fatalf("只应取超过五分钟的 pending/processing，实际 %+v", charges)
	}
	if charges[0].ID != "nc_old_pending" || charges[1].ID != "nc_old_processing" {
		t.Fatalf("应按上一次尝试时刻与创建时间升序: %+v", charges)
	}
	limited, err := st.UnsettledGlobal(ctx, now.Add(-5*time.Minute), 1)
	if err != nil || len(limited) != 1 {
		t.Fatalf("应按批次上限截断: %d %v", len(limited), err)
	}
}

// TestPostgresUnsettledGlobalRotatesAttemptedCharges 守住轮转取数：刚试过的那一笔排到
// 后面，从没试过的先取，即使它更晚创建。按创建时间取时最老的一批永远占住每次五十条
// 的名额，只要它们一直处理不掉，更晚的流水在保留期里就永远轮不到（ADR-0089）。
func TestPostgresUnsettledGlobalRotatesAttemptedCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now()
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, last_attempt_at)
		 VALUES ('nc_retried', 'u1', current_date, 1, 1000, 'pending', now() - interval '2 hours', now()),
		        ('nc_fresh', 'u1', current_date, 1, 1000, 'pending', now() - interval '10 minutes', NULL)`); err != nil {
		t.Fatalf("insert charges: %v", err)
	}
	charges, err := st.UnsettledGlobal(ctx, now.Add(-5*time.Minute), 1)
	if err != nil || len(charges) != 1 {
		t.Fatalf("补查取数: %d %v", len(charges), err)
	}
	if charges[0].ID != "nc_fresh" {
		t.Fatalf("应先取没有试过的那一笔，实际 %+v", charges)
	}
	charges, err = st.UnsettledGlobal(ctx, now.Add(-5*time.Minute), 50)
	if err != nil || len(charges) != 2 {
		t.Fatalf("第二批应同时取到两笔: %d %v", len(charges), err)
	}
	if charges[1].ID != "nc_retried" {
		t.Fatalf("刚试过的那一笔应排到后面，实际 %+v", charges)
	}
}

// TestPostgresNoteAttemptCountsAndGivesUp 守住补查的尝试计数与上限：每次尝试加一并
// 推进 last_attempt_at，超过上限的那一次落成 abandoned 并写备注，之后的补查不再取
// 它；已经终结的流水不更新，返回空状态（ADR-0089）。
func TestPostgresNoteAttemptCountsAndGivesUp(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now()
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at)
		 VALUES ('nc_1', 'u1', current_date, 1, 1000, 'pending', now() - interval '10 minutes')`); err != nil {
		t.Fatalf("insert charge: %v", err)
	}
	for attempt := 1; attempt <= 2; attempt++ {
		status, err := st.NoteAttempt(ctx, "nc_1", 2)
		if err != nil || status != nowpay.StatusPending {
			t.Fatalf("第 %d 次尝试仍应为 pending: %q %v", attempt, status, err)
		}
	}
	var attempts int32
	var lastAttemptAt time.Time
	if err := st.pool.QueryRow(ctx,
		`SELECT attempts, last_attempt_at FROM nowpay_charge WHERE id = 'nc_1'`).
		Scan(&attempts, &lastAttemptAt); err != nil {
		t.Fatalf("read charge: %v", err)
	}
	if attempts != 2 || lastAttemptAt.IsZero() {
		t.Fatalf("应记下两次尝试与尝试时刻: attempts=%d at=%v", attempts, lastAttemptAt)
	}
	status, err := st.NoteAttempt(ctx, "nc_1", 2)
	if err != nil || status != nowpay.StatusAbandoned {
		t.Fatalf("超过上限应落成 abandoned: %q %v", status, err)
	}
	var note string
	if err := st.pool.QueryRow(ctx,
		`SELECT note FROM nowpay_charge WHERE id = 'nc_1'`).Scan(&note); err != nil {
		t.Fatalf("read note: %v", err)
	}
	if note == "" {
		t.Fatal("落成 abandoned 时应写一条备注")
	}
	if charges, err := st.UnsettledGlobal(ctx, now.Add(-5*time.Minute), 50); err != nil || len(charges) != 0 {
		t.Fatalf("落成 abandoned 的流水不应再被补查取到: %+v %v", charges, err)
	}
	if status, err := st.NoteAttempt(ctx, "nc_1", 2); err != nil || status != "" {
		t.Fatalf("已经终结的流水不应再被更新: %q %v", status, err)
	}
	counts, err := st.ChargeStatusCounts(ctx)
	if err != nil {
		t.Fatalf("charge status counts: %v", err)
	}
	if counts[nowpay.StatusAbandoned] != 1 {
		t.Fatalf("放弃补查的流水应计入 abandoned: %+v", counts)
	}
}

// TestPostgresPrunesExpiredPurchasesAndTerminalCharges 守住保留期边界：购买入口按过期
// 30 天、核销流水按终态更新 180 天删除，pending 不删；补查放弃的 abandoned 也算终态，
// 跟着一起清理（ADR-0089）。
func TestPostgresPrunesExpiredPurchasesAndTerminalCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now()
	for _, purchase := range []struct {
		id      string
		expires time.Time
	}{
		{"np_old", now.AddDate(0, 0, -31)},
		{"np_keep", now.AddDate(0, 0, -29)},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_purchase (out_request_no, client_request_no, user_id, state, purchase_url, expires_at)
			 VALUES ($1, $1, 'u1', 'ready', 'alipays://x', $2)`,
			purchase.id, purchase.expires); err != nil {
			t.Fatalf("insert purchase: %v", err)
		}
	}
	for _, charge := range []struct {
		id      string
		status  string
		updated time.Time
	}{
		{"nc_old_succeeded", nowpay.StatusSucceeded, now.AddDate(0, 0, -181)},
		{"nc_old_failed", nowpay.StatusFailed, now.AddDate(0, 0, -181)},
		{"nc_old_abandoned", nowpay.StatusAbandoned, now.AddDate(0, 0, -181)},
		{"nc_keep_succeeded", nowpay.StatusSucceeded, now.AddDate(0, 0, -179)},
		{"nc_old_pending", nowpay.StatusPending, now.AddDate(0, 0, -181)},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, updated_at)
			 VALUES ($1, 'u1', '2026-11-25'::date, 1, 10000, $2, $3, $3)`,
			charge.id, charge.status, charge.updated); err != nil {
			t.Fatalf("insert charge: %v", err)
		}
	}
	deleted, err := st.DeleteExpiredPurchases(ctx, now.AddDate(0, 0, -30), 1000)
	if err != nil || deleted != 1 {
		t.Fatalf("应删除过期 30 天以上的购买入口: %d %v", deleted, err)
	}
	deleted, err = st.DeleteTerminalCharges(ctx, now.AddDate(0, 0, -180), 1000)
	if err != nil || deleted != 3 {
		t.Fatalf("应删除终态超过 180 天的流水: %d %v", deleted, err)
	}
	var charges, purchases int64
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM nowpay_charge`).Scan(&charges); err != nil {
		t.Fatalf("count: %v", err)
	}
	if charges != 2 {
		t.Fatalf("保留的流水应为 2 条（pending 与未到期的终态），实际 %d", charges)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM nowpay_purchase`).Scan(&purchases); err != nil {
		t.Fatalf("count: %v", err)
	}
	if purchases != 1 {
		t.Fatalf("保留的购买入口应为 1 条，实际 %d", purchases)
	}
	counts, err := st.ChargeStatusCounts(ctx)
	if err != nil {
		t.Fatalf("charge status counts: %v", err)
	}
	if counts[nowpay.StatusSucceeded] != 1 || counts[nowpay.StatusPending] != 1 {
		t.Fatalf("按状态计数不对: %+v", counts)
	}
}

// TestPostgresClaimCharge 核对发送核销之前的本地认领：同一笔流水在租约之内只能被
// 认领一次，租约过去之后可以重新认领（进程在认领之后退出时靠这一点重发），已经落了
// 终态的流水不再被认领（ADR-0088）。
func TestPostgresClaimCharge(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 1000,
	})
	if err != nil || !ok {
		t.Fatalf("写流水: ok=%v err=%v", ok, err)
	}
	if claimed, err := st.ClaimCharge(ctx, charge.ID, time.Minute); err != nil || !claimed {
		t.Fatalf("第一次认领应成功: %v %v", claimed, err)
	}
	if claimed, err := st.ClaimCharge(ctx, charge.ID, time.Minute); err != nil || claimed {
		t.Fatalf("租约之内不应重复认领: %v %v", claimed, err)
	}
	if claimed, err := st.ClaimCharge(ctx, charge.ID, 0); err != nil || !claimed {
		t.Fatalf("租约过去之后应能重新认领: %v %v", claimed, err)
	}
	if _, err := st.SetStatus(ctx, charge.ID, nowpay.StatusSucceeded, ""); err != nil {
		t.Fatalf("落状态: %v", err)
	}
	if claimed, err := st.ClaimCharge(ctx, charge.ID, 0); err != nil || claimed {
		t.Fatalf("终态流水不应再被认领: %v %v", claimed, err)
	}
}

// TestPostgresRefusesToStartWithoutTheClaimColumn 守住认领列的启动检查：缺列时每一笔
// 核销都发不出去，服务启动时直接拒绝，由自动部署回滚到上一份文件（ADR-0088）。
func TestPostgresRefusesToStartWithoutTheClaimColumn(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	enablePaidQuota(t, st)
	if _, err := st.pool.Exec(ctx, `ALTER TABLE nowpay_charge DROP COLUMN claimed_at`); err != nil {
		t.Fatalf("drop column: %v", err)
	}
	if err := st.CheckNowPaySchema(ctx); err == nil {
		t.Fatal("缺 claimed_at 列时启动应失败")
	}
}

// TestPostgresRefusesToStartWithoutTheAttemptColumns 守住补查尝试的启动检查：缺列时
// 补查写不进尝试、取数也轮转不起来，积压会重新饿死更晚的流水（ADR-0089）。
func TestPostgresRefusesToStartWithoutTheAttemptColumns(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	enablePaidQuota(t, st)
	if _, err := st.pool.Exec(ctx, `ALTER TABLE nowpay_charge DROP COLUMN attempts`); err != nil {
		t.Fatalf("drop column: %v", err)
	}
	if err := st.CheckNowPaySchema(ctx); err == nil {
		t.Fatal("缺 attempts 列时启动应失败")
	}
}

// TestPostgresRefusesToStartWithoutTheAbandonedStatus 守住状态约束的启动检查：约束还
// 只认四个状态时，超过上限的流水落不成终态，补查会一直重试同一批（ADR-0089）。
func TestPostgresRefusesToStartWithoutTheAbandonedStatus(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	enablePaidQuota(t, st)
	if _, err := st.pool.Exec(ctx, `ALTER TABLE nowpay_charge DROP CONSTRAINT nowpay_charge_status_check`); err != nil {
		t.Fatalf("drop constraint: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `ALTER TABLE nowpay_charge ADD CONSTRAINT nowpay_charge_status_check
		CHECK (status IN ('pending', 'processing', 'succeeded', 'failed'))`); err != nil {
		t.Fatalf("add constraint: %v", err)
	}
	if err := st.CheckNowPaySchema(ctx); err == nil {
		t.Fatal("状态约束不含 abandoned 时启动应失败")
	}
}
