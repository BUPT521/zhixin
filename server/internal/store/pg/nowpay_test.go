package pg

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/nowpay"
	"github.com/BUPT521/zhixin/server/internal/store/db"
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
	// coalesced 为真时 RefreshBalance 报告这次没有入队，模拟一分钟合并窗口里的
	// 重复请求。
	coalesced bool
}

func (f *fakeRecorder) Record(_ context.Context, _, _ string, chargeable int64) {
	f.charged = append(f.charged, chargeable)
}

func (f *fakeRecorder) Resume(context.Context, string) {}

func (f *fakeRecorder) RefreshBalance(_ context.Context, userID string) bool {
	f.refreshed = append(f.refreshed, userID)
	return !f.coalesced
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
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
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
	st.SetQuotaLimits(100, 0, 0)
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
	if err := st.SaveBalance(ctx, "u1", -3, time.Now()); err != nil {
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
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	}, 20)
	if err != nil || !ok || charge.Points != 5 {
		t.Fatalf("应只申请副本里的五积分: %+v %v %v", charge, ok, err)
	}
	if _, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_2", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	}, 20); err != nil || ok {
		t.Fatalf("副本已被占满时不该再写流水: %v %v", ok, err)
	}
}

// TestPostgresReservePointsSubtractsUnreflectedCharges 守住副本之外还没有反映的核销
// 也占着余额：副本五积分、两积分待确认时，当天合计最多申请三积分，这次只补一积分
// （ADR-0073）。
func TestPostgresReservePointsSubtractsUnreflectedCharges(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
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
	}, 20)
	if err != nil || !ok || charge.Points != 1 {
		t.Fatalf("当天合计应只申请三积分，这次补一积分: %+v %v %v", charge, ok, err)
	}
}

// TestPostgresReservePointsWithoutBalanceCopyChargesInFull 守住读不到副本时不截断：
// 没有副本行、余额表未就绪或读取失败都按整额申请，一次读取失败不会少记账。
func TestPostgresReservePointsWithoutBalanceCopyChargesInFull(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	enablePaidQuota(t, st)
	charge, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	}, 20)
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
	if err := st.SaveBalance(ctx, "u1", 0, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	if _, ok, err := st.ReservePoints(ctx, nowpay.Charge{
		ID: "nc_1", UserID: "u1", Day: "2026-11-25", Tokens: 20000,
	}, 20); err != nil || ok {
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
	st.SetQuotaLimits(1_000_000, 1_000_000, 1000)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 150); err != nil {
				return
			}
			_ = st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 150, 150, llmproxy.Usage{Input: 150})
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
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
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
	st.SetQuotaLimits(100, 0, 0)

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
	st.SetQuotaLimits(100, 0, 0)
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
	row, err := st.q.BalanceForReserve(ctx, "u1")
	if err != nil {
		t.Fatalf("read balance: %v", err)
	}
	if row.RemainingPoints != 5 || !row.SyncedAt.Time.Equal(base) {
		t.Fatalf("旧快照不应覆盖新副本，得到 %d %v", row.RemainingPoints, row.SyncedAt.Time)
	}
	if err := st.SaveBalance(ctx, "u1", 7, base.Add(time.Minute)); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	row, err = st.q.BalanceForReserve(ctx, "u1")
	if err != nil {
		t.Fatalf("read balance: %v", err)
	}
	if row.RemainingPoints != 7 || !row.SyncedAt.Time.Equal(base.Add(time.Minute)) {
		t.Fatalf("新快照应覆盖副本，得到 %d %v", row.RemainingPoints, row.SyncedAt.Time)
	}
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
	for _, charge := range []struct {
		id      string
		status  string
		points  int64
		created time.Time
		updated time.Time
	}{
		{"nc_pending_old", nowpay.StatusPending, 1, asOf.Add(-time.Hour), asOf.Add(-time.Hour)},
		{"nc_succeeded_new", nowpay.StatusSucceeded, 2, asOf.Add(-time.Hour), asOf.Add(time.Minute)},
		{"nc_succeeded_old", nowpay.StatusSucceeded, 4, asOf.Add(-2 * time.Hour), asOf.Add(-time.Hour)},
		{"nc_failed_new", nowpay.StatusFailed, 8, asOf.Add(-time.Hour), asOf.Add(time.Minute)},
	} {
		if _, err := st.pool.Exec(ctx,
			`INSERT INTO nowpay_charge (id, user_id, day, points, billed_tokens, status, created_at, updated_at)
			 VALUES ($1, 'u1', '2026-11-25'::date, $2, $2, $3, $4, $5)`,
			charge.id, charge.points, charge.status, charge.created, charge.updated); err != nil {
			t.Fatalf("insert charge: %v", err)
		}
	}
	got, err := st.q.UnreflectedChargePoints(ctx, db.UnreflectedChargePointsParams{
		UserID: text("u1"), AsOf: pgtype.Timestamptz{Time: asOf, Valid: true},
	})
	if err != nil {
		t.Fatalf("unreflected: %v", err)
	}
	if got != 3 {
		t.Fatalf("未反映的积分应为 pending 1 + 快照后成功的 2 = 3，得到 %d", got)
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
// 期、仍然 pending 或 processing 的流水，按创建时间升序，结果上限按批次。
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
		t.Fatalf("应按创建时间升序: %+v", charges)
	}
	limited, err := st.UnsettledGlobal(ctx, now.Add(-5*time.Minute), 1)
	if err != nil || len(limited) != 1 {
		t.Fatalf("应按批次上限截断: %d %v", len(limited), err)
	}
}

// TestPostgresPrunesExpiredPurchasesAndTerminalCharges 守住保留期边界：购买入口按过期
// 30 天、核销流水按终态更新 180 天删除，pending 不删。
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
	if err != nil || deleted != 2 {
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
