package pg

import (
	"context"
	"errors"
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

// TestPostgresAvailablePointsReadsTheBalanceCopy 守住核销侧的读法：余额表未建好或
// 账号还没有副本行时按未知返回，有行时返回副本里的剩余积分，核销据此决定是否按
// 副本收口申请量（ADR-0069）。
func TestPostgresAvailablePointsReadsTheBalanceCopy(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	// 余额副本表还没建好：按未知返回，不报错。
	if points, known, err := st.AvailablePoints(ctx, "u1"); err != nil || known || points != 0 {
		t.Fatalf("余额表未建好时应按未知返回，得到 %d %v %v", points, known, err)
	}
	enablePaidQuota(t, st)
	// 表已建好但账号还没有副本行：同样按未知返回。
	if points, known, err := st.AvailablePoints(ctx, "u1"); err != nil || known || points != 0 {
		t.Fatalf("没有副本行时应按未知返回，得到 %d %v %v", points, known, err)
	}
	if err := st.SaveBalance(ctx, "u1", 7, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}
	points, known, err := st.AvailablePoints(ctx, "u1")
	if err != nil || !known || points != 7 {
		t.Fatalf("有副本时应返回剩余积分 7，得到 %d %v %v", points, known, err)
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
