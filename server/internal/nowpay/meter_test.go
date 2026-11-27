package nowpay

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

type statusChange struct {
	id, status, note string
}

// fakeLedger 是核销流水的测试替身。mu 保护下面全部字段：核销队列与余额刷新队列
// 各有一个协程，两者都会调用 SaveBalance（ADR-0073 把余额查询拆出去正是为了让它们
// 互不阻塞），生产实现由数据库事务与快照下限保证并发安全，替身自己也要加锁，否则
// go test -race 会在这种并发写入上失败。
type fakeLedger struct {
	mu        sync.Mutex
	applied   int64
	created   []Charge
	unsettled []Charge
	// unsettledGlobal 是全局补查返回的流水。
	unsettledGlobal []Charge
	statuses        []statusChange
	balances        map[string]int64
	// balanceAsOf 记每次写副本带的快照时刻。
	balanceAsOf map[string]time.Time
	// confirmAt 是每次落状态返回的确认时刻；零值表示这次没有可用的确认时刻。
	confirmAt time.Time

	// capAt 与 capped 模拟 ReservePoints 按余额副本收口：capped 为真时申请量截到
	// capAt，capAt 为零表示副本没有余额，不写流水。
	capAt  int64
	capped bool
	// reserveErr 让用例模拟写流水失败。
	reserveErr error
	// statusEvents 非空时，每次落状态都往这个通道发一份，供并发用例等待结果。
	statusEvents chan statusChange
	// claimDenied 里的流水编号模拟被别的路径认领：ClaimCharge 对它返回 false；
	// claimErr 让用例模拟认领本身失败；claimedIDs 记下每次成功的认领。
	claimDenied map[string]bool
	claimErr    error
	claimedIDs  []string
	// attemptStatus 是 NoteAttempt 对某笔流水返回的状态，没有预设的按 pending 记；
	// attemptIDs 记下每次补查尝试的流水编号，供用例核对轮转取到的是哪几笔。
	attemptStatus map[string]string
	attemptIDs    []string
}

func (f *fakeLedger) ReservePoints(_ context.Context, charge Charge, required int64) (Charge, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.reserveErr != nil {
		return Charge{}, false, f.reserveErr
	}
	if f.capped {
		if f.capAt <= 0 {
			return Charge{}, false, nil
		}
		required = min(required, f.capAt)
	}
	if required <= f.applied {
		return Charge{}, false, nil
	}
	charge.Points = required - f.applied
	f.applied = required
	f.created = append(f.created, charge)
	return charge, true, nil
}

func (f *fakeLedger) SaveBalance(_ context.Context, userID string, remaining int64, asOf time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.balances == nil {
		f.balances = map[string]int64{}
	}
	if f.balanceAsOf == nil {
		f.balanceAsOf = map[string]time.Time{}
	}
	f.balances[userID] = remaining
	f.balanceAsOf[userID] = asOf
	return nil
}

func (f *fakeLedger) Unsettled(context.Context, string, int) ([]Charge, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.unsettled, nil
}

func (f *fakeLedger) UnsettledGlobal(context.Context, time.Time, int) ([]Charge, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.unsettledGlobal, nil
}

func (f *fakeLedger) ClaimCharge(_ context.Context, id string, _ time.Duration) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.claimErr != nil {
		return false, f.claimErr
	}
	if f.claimDenied[id] {
		return false, nil
	}
	f.claimedIDs = append(f.claimedIDs, id)
	return true, nil
}

func (f *fakeLedger) NoteAttempt(_ context.Context, id string, _ int) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.attemptIDs = append(f.attemptIDs, id)
	if status, ok := f.attemptStatus[id]; ok {
		return status, nil
	}
	return StatusPending, nil
}

func (f *fakeLedger) SetStatus(_ context.Context, id, status, note string) (time.Time, error) {
	change := statusChange{id: id, status: status, note: note}
	f.mu.Lock()
	f.statuses = append(f.statuses, change)
	confirmAt, events := f.confirmAt, f.statusEvents
	f.mu.Unlock()
	// 事件在锁外发送：通道满了要等用例读取，持锁等待会把下一次 SetStatus 卡住。
	if events != nil {
		events <- change
	}
	return confirmAt, nil
}

func (f *fakeLedger) last() statusChange {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.statuses) == 0 {
		return statusChange{}
	}
	return f.statuses[len(f.statuses)-1]
}

func newTestMeter(t *testing.T, ledger *fakeLedger, caller *fakeCaller) *Meter {
	t.Helper()
	meter, err := NewMeter(newTestClient(t, caller), ledger, 1000, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	return meter
}

func TestRecordChargesOnlyTokensAboveTheFreeAllowance(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 2500)
	if len(ledger.created) != 1 {
		t.Fatalf("应写一条待核销流水，实际 %d 条", len(ledger.created))
	}
	if ledger.created[0].Points != 3 || ledger.created[0].Tokens != 2500 {
		t.Fatalf("2500 计费 token 应按 1 积分 1000 token 向上取整为 3 积分: %+v", ledger.created[0])
	}
	if ledger.created[0].Status != StatusPending {
		t.Fatalf("新流水应为 pending: %+v", ledger.created[0])
	}
}

func TestRecordDoesNotChargeAgainWhenTheSameDayIsSettledTwice(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 2500)
	meter.Record(context.Background(), "user_1", "2026-11-25", 2800)
	if len(ledger.created) != 1 {
		t.Fatalf("同一账号同一天的第二次结算只补差额，不该再扣一笔: %d 条", len(ledger.created))
	}
	meter.Record(context.Background(), "user_1", "2026-11-25", 5200)
	if len(ledger.created) != 2 || ledger.created[1].Points != 3 {
		t.Fatalf("用量涨到 5200 时应补 3 个积分: %+v", ledger.created)
	}
}

func TestRecordChargesTheDaysCumulativeTotalOnce(t *testing.T) {
	ledger := &fakeLedger{}
	meter, err := NewMeter(newTestClient(t, &fakeCaller{}), ledger, 10000,
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	// 十二轮各 12,480 个计费 token，按当天累计是 14.976 个积分，记 15 个；逐轮取整
	// 会记 24 个，差额不再随轮次放大（ADR-0067）。
	for i := 1; i <= 12; i++ {
		meter.Record(context.Background(), "user_1", "2026-11-25", int64(12480*i))
	}
	var total int64
	for _, c := range ledger.created {
		total += c.Points
	}
	if total != 15 {
		t.Fatalf("十二轮累计应记 15 个积分，逐轮取整会记 24 个: 实际 %d 个 %+v", total, ledger.created)
	}
}

func TestRecordWithoutChargeableTokensDoesNothing(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 0)
	meter.Record(context.Background(), "user_1", "2026-11-25", -10)
	if len(ledger.created) != 0 {
		t.Fatalf("没有超出免费额度的用量不该产生核销: %+v", ledger.created)
	}
}

// TestRecordQueuesWhateverTheLedgerReserved 守住收口在 ReservePoints 一处：流水已经按
// 副本截断过时，核销按截断后的积分排队；ReservePoints 说不用申请时既不写流水也不
// 排队（ADR-0073）。
func TestRecordQueuesWhateverTheLedgerReserved(t *testing.T) {
	ledger := &fakeLedger{capped: true, capAt: 5}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 20000)
	if len(ledger.created) != 1 || ledger.created[0].Points != 5 {
		t.Fatalf("应写一条按副本截断后的流水: %+v", ledger.created)
	}
	if len(meter.queue) != 1 {
		t.Fatalf("截断后的流水应排队核销，实际队列 %d", len(meter.queue))
	}
	if next := <-meter.queue; next.charge.Points != 5 {
		t.Fatalf("队列里的积分应为截断后的五积分: %+v", next)
	}
}

// TestRecordStopsWhenTheLedgerRefuses 守住余额为零时不重复申请：ReservePoints 返回
// 不用申请时，既不排队核销，也不调用即刻收。
func TestRecordStopsWhenTheLedgerRefuses(t *testing.T) {
	caller := &fakeCaller{}
	ledger := &fakeLedger{capped: true}
	meter := newTestMeter(t, ledger, caller)
	meter.Record(context.Background(), "user_1", "2026-11-25", 20000)
	if len(ledger.created) != 0 || len(meter.queue) != 0 || len(caller.methods) != 0 {
		t.Fatalf("余额为零时不该写流水、排队或调用即刻收: %+v queue=%d methods=%v",
			ledger.created, len(meter.queue), caller.methods)
	}
}

func TestRunMarksSucceededOnlyOnConfirmedConsume(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","consumed":3,"remaining":97}`,
	}}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if caller.methods[0] != methodVerify {
		t.Fatalf("首轮应发起核销，实际 %s", caller.methods[0])
	}
	if got := ledger.last(); got.status != StatusSucceeded {
		t.Fatalf("SUCCEEDED 应落成功: %+v", got)
	}
	// 响应里的剩余积分是余额副本的下一个值，额度预留按它放行（ADR-0069）。
	if ledger.balances["user_1"] != 97 {
		t.Fatalf("核销成功应把剩余积分写进副本: %+v", ledger.balances)
	}
}

// TestSucceededChargeSavesTheCopyAtTheResponseSnapshot 守住副本的时间语义：核销结果
// 带了 as_of_time 就用它写 synced_at，副本据此判断哪些核销还没有被反映（ADR-0073）。
func TestSucceededChargeSavesTheCopyAtTheResponseSnapshot(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","consumed":3,"remaining":97,
			"as_of_time":"2026-11-25 10:00:00"}`,
	}}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	want := time.Date(2026, 11, 25, 10, 0, 0, 0, ChinaTime())
	if !ledger.balanceAsOf["user_1"].Equal(want) {
		t.Fatalf("副本应按响应的快照时间写入，得到 %v", ledger.balanceAsOf["user_1"])
	}
}

// TestSucceededChargeSavesTheCopyNoEarlierThanTheConfirmation 守住副本快照不早于这一笔
// 的确认时刻：响应给的 as_of_time 早于本地确认时间时，拿响应时刻写 synced_at 会让这一
// 笔自己被算成“快照之后才确认”，可用积分少一笔直到下一次查询，所以取较晚的那个。
func TestSucceededChargeSavesTheCopyNoEarlierThanTheConfirmation(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","consumed":3,"remaining":97,
			"as_of_time":"2026-11-25 10:00:00"}`,
	}}
	confirmed := time.Date(2026, 11, 25, 10, 0, 1, 0, ChinaTime())
	ledger := &fakeLedger{confirmAt: confirmed}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if got := ledger.balanceAsOf["user_1"]; !got.Equal(confirmed) {
		t.Fatalf("副本快照不应早于确认时刻，want %v got %v", confirmed, got)
	}
}

// TestFailedChargeSavesTheReportedRemaining 守住失败结果也更新副本：FAILED 表示确认
// 没有扣减，响应里的剩余积分仍然是一次有效的余额快照。
func TestFailedChargeSavesTheReportedRemaining(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"FAILED","remaining":42}`,
	}}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if ledger.balances["user_1"] != 42 {
		t.Fatalf("FAILED 应把响应里的剩余积分写进副本: %+v", ledger.balances)
	}
}

// TestProcessingDoesNotOverwriteTheCopy 守住 PROCESSING 的剩余积分不当余额：它是否
// 已经扣住这笔预占还没有确认，拿来覆盖副本会让副本偏低（ADR-0073）。
func TestProcessingDoesNotOverwriteTheCopy(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"PROCESSING","remaining":10}`,
	}}
	ledger := &fakeLedger{balances: map[string]int64{"user_1": 50}}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if ledger.balances["user_1"] != 50 {
		t.Fatalf("PROCESSING 不应覆盖副本: %+v", ledger.balances)
	}
}

// TestNonPointChargeIsNotBookedAsPoints 守住核销结果的单位校验：响应不是按积分时
// 不按积分记账、不覆盖副本，记失败等下一次结算重算（ADR-0073）。
func TestNonPointChargeIsNotBookedAsPoints(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","remaining":10,"quota_unit":"COUNT"}`,
	}}
	ledger := &fakeLedger{balances: map[string]int64{"user_1": 50}}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if got := ledger.last(); got.status != StatusFailed {
		t.Fatalf("单位不是积分时应记失败: %+v", got)
	}
	if ledger.balances["user_1"] != 50 {
		t.Fatalf("单位不是积分时不该覆盖副本: %+v", ledger.balances)
	}
}

// TestRefreshSkipsANonPointProduct 守住后台刷新也校验单位：不是按积分卖的商品，余额
// 不能写进按积分放行的副本（ADR-0073）。
func TestRefreshSkipsANonPointProduct(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodQuota: `{"code":"10000","quota_unit":"COUNT","total":10,"used":3,"remaining":7}`,
	}}
	ledger := &fakeLedger{balances: map[string]int64{"user_1": 50}}
	meter := newTestMeter(t, ledger, caller)
	meter.run(context.Background(), job{balance: true, userID: "user_1"})
	if ledger.balances["user_1"] != 50 {
		t.Fatalf("单位不是积分时不该覆盖副本: %+v", ledger.balances)
	}
}

func TestProcessingIsQueriedWithTheSameRequestNo(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify:  `{"code":"10000","consume_status":"PROCESSING","quota_unit":"POINT"}`,
		methodRefresh: `{"code":"10000","consume_status":"SUCCEEDED","consumed":3,"remaining":97}`,
	}}
	ledger := &fakeLedger{balances: map[string]int64{"user_1": 50}}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if got := ledger.last(); got.status != StatusProcessing {
		t.Fatalf("PROCESSING 应记为处理中: %+v", got)
	}
	// PROCESSING 的响应通常不带剩余积分，零值不能被当成“余额为零”覆盖副本。
	if ledger.balances["user_1"] != 50 {
		t.Fatalf("没有剩余积分的响应不能改动副本: %+v", ledger.balances)
	}
	meter.run(context.Background(), job{charge: charge})
	if caller.methods[1] != methodRefresh {
		t.Fatalf("补查应走 quota.refresh，实际 %s", caller.methods[1])
	}
	if caller.biz[1]["out_request_no"] != "nc_1" {
		t.Fatalf("补查必须用原请求号: %v", caller.biz[1])
	}
	if got := ledger.last(); got.status != StatusSucceeded {
		t.Fatalf("补查确认后应落成功: %+v", got)
	}
	if ledger.balances["user_1"] != 97 {
		t.Fatalf("补查确认后应把剩余积分写进副本: %+v", ledger.balances)
	}
}

func TestGatewayFailureKeepsTheChargePendingAndNotesTheReason(t *testing.T) {
	caller := &fakeCaller{err: ErrGatewayForTest}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	got := ledger.last()
	if got.status != "" {
		t.Fatalf("未知结果不能判成功或失败: %+v", got)
	}
	if got.note == "" {
		t.Fatal("未知结果应记下原因，方便排查")
	}
}

func TestInsufficientPointsIsMarkedFailedForTheNextSettlement(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"40004","sub_code":"NOW_PAY_QUOTA_INSUFFICIENT","sub_msg":"额度不足"}`,
	}}
	ledger := &fakeLedger{balances: map[string]int64{"user_1": 40}}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if got := ledger.last(); got.status != StatusFailed {
		t.Fatalf("余额不足应记失败，让下次结算重算差额: %+v", got)
	}
	// 副本比实际高才会走到这里，按零覆盖之后下一次预留不再按旧值放行。
	if ledger.balances["user_1"] != 0 {
		t.Fatalf("余额不足应把副本清零: %+v", ledger.balances)
	}
}

func TestRefreshBalanceQueriesTheGatewayAndSavesTheCopy(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodQuota: `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55,
			"as_of_time":"2026-11-25 09:30:00"}`,
	}}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	if !meter.RefreshBalance(context.Background(), "user_1") {
		t.Fatal("第一次余额查询应入队")
	}
	if len(meter.refreshQueue) != 1 {
		t.Fatalf("应排一次余额查询，实际 %d", len(meter.refreshQueue))
	}
	next := <-meter.refreshQueue
	if !next.balance || next.userID != "user_1" {
		t.Fatalf("队列里应是一次余额查询: %+v", next)
	}
	meter.run(context.Background(), next)
	if caller.methods[0] != methodQuota {
		t.Fatalf("余额查询应走 quota.query，实际 %s", caller.methods[0])
	}
	if ledger.balances["user_1"] != 55 {
		t.Fatalf("查到的余额应写进副本: %+v", ledger.balances)
	}
	want := time.Date(2026, 11, 25, 9, 30, 0, 0, ChinaTime())
	if !ledger.balanceAsOf["user_1"].Equal(want) {
		t.Fatalf("副本应按查询响应的快照时间写入，得到 %v", ledger.balanceAsOf["user_1"])
	}
}

func TestRefreshBalanceKeepsTheOldCopyWhenTheGatewayFails(t *testing.T) {
	caller := &fakeCaller{err: ErrGatewayForTest}
	ledger := &fakeLedger{balances: map[string]int64{"user_1": 30}}
	meter := newTestMeter(t, ledger, caller)
	meter.run(context.Background(), job{balance: true, userID: "user_1"})
	// 查询失败不能当成零余额，否则还在余额内的账号会被挡在免费额度之外。
	if ledger.balances["user_1"] != 30 {
		t.Fatalf("查询失败应保留旧副本: %+v", ledger.balances)
	}
}

func TestRefreshBalanceCoalescesRepeatedRequests(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	// 额度用完之后的每个请求都会发现副本过期，同一账号一分钟内只排一次查询，
	// 不把核销队列占住。
	if !meter.RefreshBalance(context.Background(), "user_1") {
		t.Fatal("第一次查询应入队")
	}
	if meter.RefreshBalance(context.Background(), "user_1") {
		t.Fatal("同一账号一分钟内的第二次查询应合并，不入队")
	}
	if !meter.RefreshBalance(context.Background(), "user_2") {
		t.Fatal("另一个账号应单独入队")
	}
	if len(meter.refreshQueue) != 2 {
		t.Fatalf("同一账号的重复查询应合并，实际队列 %d", len(meter.refreshQueue))
	}
}

// TestBalanceRefreshDoesNotBlockCharges 守住队列拆分的目的：余额查询卡在网关时，
// 核销仍由另一个协程完成，不占核销的时间预算（ADR-0073）。
func TestBalanceRefreshDoesNotBlockCharges(t *testing.T) {
	release := make(chan struct{})
	started := make(chan string, 8)
	caller := &fakeCaller{
		blockQuota: release,
		started:    started,
		replies: map[string]string{
			methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","remaining":97}`,
			methodQuota:  `{"code":"10000","quota_unit":"POINT","remaining":10}`,
		},
	}
	ledger := &fakeLedger{statusEvents: make(chan statusChange, 4)}
	meter := newTestMeter(t, ledger, caller)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	meter.Start(ctx)
	defer close(release)
	if !meter.RefreshBalance(ctx, "user_1") {
		t.Fatal("余额查询应入队")
	}
	// 刷新协程调进 quota.query 之后才会卡在网关上，等到这一步就可以确认任务已经
	// 离开队列：按队列长度判断会随调度顺序时好时坏，CI 上的 -race 一慢就失败。
	waitForMethod(t, started, methodQuota)
	meter.enqueue(job{
		charge: Charge{ID: "nc_1", UserID: "user_1", Points: 3, Status: StatusPending},
		verify: true,
	})
	select {
	case got := <-ledger.statusEvents:
		if got.status != StatusSucceeded {
			t.Fatalf("核销应在刷新卡住时完成: %+v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("余额查询卡住时核销没有完成，说明两条队列仍互相阻塞")
	}
	// 刷新协程仍在等网关；这里只确认核销已经落库。
}

// waitForMethod 等到 fakeCaller 收到指定的 method，超过两秒按失败处理。
func waitForMethod(t *testing.T, started <-chan string, method string) {
	t.Helper()
	timeout := time.After(2 * time.Second)
	for {
		select {
		case got := <-started:
			if got == method {
				return
			}
		case <-timeout:
			t.Fatalf("两秒内没有等到 %s 调用", method)
		}
	}
}

// TestFullRefreshQueueDropsTheRefresh 守住刷新队列满时的处理：丢弃并报告没有入队，
// 不阻塞请求，也不 panic；这次没有排上的查询不占合并窗口，队列空出来之后的请求
// 仍然能再排一次。
func TestFullRefreshQueueDropsTheRefresh(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	for i := 0; i < cap(meter.refreshQueue); i++ {
		meter.refreshQueue <- job{}
	}
	if meter.RefreshBalance(context.Background(), "user_9") {
		t.Fatal("刷新队列满时应报告没有入队")
	}
	if len(meter.refreshQueue) != cap(meter.refreshQueue) {
		t.Fatalf("队列满时不该再放入任务，实际 %d", len(meter.refreshQueue))
	}
	<-meter.refreshQueue
	if !meter.RefreshBalance(context.Background(), "user_9") {
		t.Fatal("队列腾出位置之后应重新排一次查询，不能被上一次的合并窗口挡住")
	}
}

func TestResumeRetriesPendingAndOnlyRefreshesProcessing(t *testing.T) {
	ledger := &fakeLedger{unsettled: []Charge{
		{ID: "nc_1", UserID: "user_1", Points: 2, Status: StatusPending},
		{ID: "nc_2", UserID: "user_1", Points: 3, Status: StatusProcessing},
	}}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Resume(context.Background(), "user_1")
	if len(meter.queue) != 2 {
		t.Fatalf("待确认流水应排进队列，实际队列 %d", len(meter.queue))
	}
	// pending 说明上一次可能没到支付宝，按原参数重试核销才是幂等的；processing 已经
	// 发出过，只查结果。
	if first := <-meter.queue; !first.verify {
		t.Fatal("pending 流水应重试核销")
	}
	if second := <-meter.queue; second.verify {
		t.Fatal("processing 流水只查结果，不重新核销")
	}
}

func TestFullQueueLeavesTheChargeForTheNextRequest(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	for i := 0; i < cap(meter.queue); i++ {
		meter.queue <- job{}
	}
	done := make(chan struct{})
	go func() {
		meter.Record(context.Background(), "user_1", "2026-11-25", 5000)
		close(done)
	}()
	<-done
	if len(ledger.created) != 1 {
		t.Fatal("队列满时仍要写流水，下一次请求前补查")
	}
}

var ErrGatewayForTest = errors.New("nowpay: 调用 alipay.aipay.nowpaydirect.quota.verify 失败: 支付宝查单失败")

func TestNewMeterValidatesArguments(t *testing.T) {
	client := newTestClient(t, &fakeCaller{})
	if _, err := NewMeter(nil, &fakeLedger{}, 1000, nil); err == nil {
		t.Fatal("缺少客户端不能构造核销执行器")
	}
	if _, err := NewMeter(client, nil, 1000, nil); err == nil {
		t.Fatal("缺少流水存储不能构造核销执行器")
	}
	if _, err := NewMeter(client, &fakeLedger{}, 0, nil); err == nil {
		t.Fatal("折算比例必须为正")
	}
}

// TestSweepEnqueuesUnsettledCharges 守住全局补查：pending 的重试核销，processing 的
// 只查结果，返回实际入队的条数（ADR-0073 所在的整改方案 P6）。入队方式按记完尝试
// 之后的状态决定：取出来的那一份可能已经被别的路径改成 processing（ADR-0089）。
func TestSweepEnqueuesUnsettledCharges(t *testing.T) {
	ledger := &fakeLedger{
		unsettledGlobal: []Charge{
			{ID: "nc_1", UserID: "user_1", Points: 2, Status: StatusPending},
			{ID: "nc_2", UserID: "user_2", Points: 3, Status: StatusProcessing},
		},
		attemptStatus: map[string]string{"nc_1": StatusPending, "nc_2": StatusProcessing},
	}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	count, err := meter.Sweep(context.Background(), time.Now().Add(-5*time.Minute), 50)
	if err != nil || count != 2 {
		t.Fatalf("应把两条流水排进队列: %d %v", count, err)
	}
	if first := <-meter.queue; !first.verify {
		t.Fatal("pending 流水应重试核销")
	}
	if second := <-meter.queue; second.verify {
		t.Fatal("processing 流水只查结果，不重新核销")
	}
}

// TestSweepGivesUpAChargeAfterTooManyAttempts 守住补查的尝试上限：记到上限的那一笔
// 落成 abandoned 之后不再入队，也不落 failed。failed 不计入当天已申请量，下一次结算
// 会按差额重新申请，而这一笔可能已经扣过，记 failed 就等于重复扣款（ADR-0089）。
func TestSweepGivesUpAChargeAfterTooManyAttempts(t *testing.T) {
	ledger := &fakeLedger{
		unsettledGlobal: []Charge{{ID: "nc_1", UserID: "user_1", Points: 2, Status: StatusPending}},
		attemptStatus:   map[string]string{"nc_1": StatusAbandoned},
	}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	count, err := meter.Sweep(context.Background(), time.Now().Add(-5*time.Minute), 50)
	if err != nil || count != 0 {
		t.Fatalf("超过上限的流水不应入队: %d %v", count, err)
	}
	if len(meter.queue) != 0 {
		t.Fatalf("队列应为空，实际 %d", len(meter.queue))
	}
	if len(ledger.attemptIDs) != 1 || ledger.attemptIDs[0] != "nc_1" {
		t.Fatalf("应记一次补查尝试: %v", ledger.attemptIDs)
	}
	if got := ledger.last(); got.status != "" {
		t.Fatalf("放弃补查不落状态，实际 %+v", got)
	}
}

// TestSweepSkipsAChargeSettledWhileSweeping 守住取数之后流水已经被别处终结的情况：
// 记尝试时拿不到状态，这一份既不入队也不落状态，等下一轮补查看新的状态。
func TestSweepSkipsAChargeSettledWhileSweeping(t *testing.T) {
	ledger := &fakeLedger{
		unsettledGlobal: []Charge{{ID: "nc_1", UserID: "user_1", Points: 2, Status: StatusPending}},
		attemptStatus:   map[string]string{"nc_1": ""},
	}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	count, err := meter.Sweep(context.Background(), time.Now().Add(-5*time.Minute), 50)
	if err != nil || count != 0 {
		t.Fatalf("已经终结的流水不应入队: %d %v", count, err)
	}
	if len(meter.queue) != 0 {
		t.Fatalf("队列应为空，实际 %d", len(meter.queue))
	}
}

// TestResumeQueuesAChargeOnce 守住本地的去重：请求前的补查、全局补查与写流水之后的
// 入队都可能把同一笔流水排一次，同一时刻队列里只留一份，也不会因为每来一次请求就
// 多一份核销（ADR-0088）。
func TestResumeQueuesAChargeOnce(t *testing.T) {
	charge := Charge{ID: "nc_1", UserID: "user_1", Points: 2, Status: StatusPending}
	ledger := &fakeLedger{unsettled: []Charge{charge}, unsettledGlobal: []Charge{charge}}
	caller := &fakeCaller{replies: map[string]string{
		methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","consumed":2}`,
	}}
	meter := newTestMeter(t, ledger, caller)

	meter.Resume(context.Background(), "user_1")
	meter.Resume(context.Background(), "user_1")
	if len(meter.queue) != 1 {
		t.Fatalf("同一笔流水应只排一次，实际队列 %d", len(meter.queue))
	}
	if count, err := meter.Sweep(context.Background(), time.Now(), 50); err != nil || count != 0 {
		t.Fatalf("已经在队列里的流水不应再排一次: %d %v", count, err)
	}

	// 这一份任务跑完之后释放认领，下一轮补查可以再排它。
	meter.run(context.Background(), <-meter.queue)
	if count, err := meter.Sweep(context.Background(), time.Now(), 50); err != nil || count != 1 {
		t.Fatalf("任务结束之后应能再排一次: %d %v", count, err)
	}
}

// TestRunSkipsAChargeAnotherPathClaimed 核对发送之前的认领：认领不到（别的路径正在
// 发，或者认领本身失败）时不发核销、不落状态，流水留给下一轮补查（ADR-0088）。
func TestRunSkipsAChargeAnotherPathClaimed(t *testing.T) {
	for _, test := range []struct {
		name   string
		ledger *fakeLedger
	}{
		{name: "被别的路径认领", ledger: &fakeLedger{claimDenied: map[string]bool{"nc_1": true}}},
		{name: "认领失败", ledger: &fakeLedger{claimErr: errors.New("pg: 认领核销流水失败")}},
	} {
		t.Run(test.name, func(t *testing.T) {
			caller := &fakeCaller{replies: map[string]string{
				methodVerify: `{"code":"10000","consume_status":"SUCCEEDED","consumed":2}`,
			}}
			meter := newTestMeter(t, test.ledger, caller)
			charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 2, Status: StatusPending}
			meter.run(context.Background(), job{charge: charge, verify: true})
			if calls := caller.calls(); len(calls) != 0 {
				t.Fatalf("认领不到时不应发送核销，实际调用 %v", calls)
			}
			if got := test.ledger.last(); got.status != "" {
				t.Fatalf("认领不到时不应落状态，实际 %+v", got)
			}
		})
	}
}
