package nowpay

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
)

type statusChange struct {
	id, status, note string
}

type fakeLedger struct {
	applied   int64
	created   []Charge
	unsettled []Charge
	statuses  []statusChange
	balances  map[string]int64

	// available 与 balanceKnown 模拟余额副本；known 为假表示副本缺失或余额表未就绪。
	available    int64
	balanceKnown bool
	// availableErr 让用例模拟读取副本失败。
	availableErr error
}

func (f *fakeLedger) AvailablePoints(context.Context, string) (int64, bool, error) {
	if f.availableErr != nil {
		return 0, false, f.availableErr
	}
	return f.available, f.balanceKnown, nil
}

func (f *fakeLedger) ReservePoints(_ context.Context, charge Charge, required int64) (Charge, bool, error) {
	if required <= f.applied {
		return Charge{}, false, nil
	}
	charge.Points = required - f.applied
	f.applied = required
	f.created = append(f.created, charge)
	return charge, true, nil
}

func (f *fakeLedger) SaveBalance(_ context.Context, userID string, remaining int64) error {
	if f.balances == nil {
		f.balances = map[string]int64{}
	}
	f.balances[userID] = remaining
	return nil
}

func (f *fakeLedger) Unsettled(context.Context, string, int) ([]Charge, error) {
	return f.unsettled, nil
}

func (f *fakeLedger) SetStatus(_ context.Context, id, status, note string) error {
	f.statuses = append(f.statuses, statusChange{id: id, status: status, note: note})
	return nil
}

func (f *fakeLedger) last() statusChange {
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

// TestRecordSkipsTheChargeWhenTheBalanceCopyIsExhausted 守住余额不足不重复申请：failed
// 流水不计入当天已申请量，副本已知为零时再申请只会每轮多一条流水、多一次核销失败。
func TestRecordSkipsTheChargeWhenTheBalanceCopyIsExhausted(t *testing.T) {
	caller := &fakeCaller{}
	ledger := &fakeLedger{balanceKnown: true}
	meter := newTestMeter(t, ledger, caller)
	meter.Record(context.Background(), "user_1", "2026-11-25", 20000)
	if len(ledger.created) != 0 {
		t.Fatalf("余额为零时不该写流水: %+v", ledger.created)
	}
	if len(meter.queue) != 0 || len(caller.methods) != 0 {
		t.Fatalf("余额为零时不该排队核销或调用即刻收: queue=%d methods=%v",
			len(meter.queue), caller.methods)
	}
}

// TestRecordCapsTheChargeAtTheBalanceCopy 守住截断而不是跳过：副本有五积分、应扣二十
// 积分时先申请五积分，把已有余额先扣掉，差额等余额补上后的下一次结算再算。
func TestRecordCapsTheChargeAtTheBalanceCopy(t *testing.T) {
	ledger := &fakeLedger{available: 5, balanceKnown: true}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 20000)
	if len(ledger.created) != 1 {
		t.Fatalf("应写一条截断后的流水: %+v", ledger.created)
	}
	if ledger.created[0].Points != 5 {
		t.Fatalf("应扣二十积分时只能申请副本里的五积分: %+v", ledger.created[0])
	}
	if len(meter.queue) != 1 {
		t.Fatalf("截断后的流水应排队核销，实际队列 %d", len(meter.queue))
	}
}

// TestRecordChargesTheFullAmountWhenTheBalanceCopyIsUnknown 守住副本未知时不截断：
// 没有行或余额表未就绪时沿用原来的整额申请，由核销结果再去修正副本。
func TestRecordChargesTheFullAmountWhenTheBalanceCopyIsUnknown(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 20000)
	if len(ledger.created) != 1 || ledger.created[0].Points != 20 {
		t.Fatalf("副本未知时应整额申请二十积分: %+v", ledger.created)
	}
}

// TestRecordChargesTheFullAmountWhenTheBalanceCopyCannotBeRead 守住读取失败按未知处理：
// 不能因为一次读失败就少记账或跳过申请。
func TestRecordChargesTheFullAmountWhenTheBalanceCopyCannotBeRead(t *testing.T) {
	ledger := &fakeLedger{availableErr: errors.New("pg: 读取积分余额副本失败")}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 20000)
	if len(ledger.created) != 1 || ledger.created[0].Points != 20 {
		t.Fatalf("读取副本失败时应整额申请二十积分: %+v", ledger.created)
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
		methodQuota: `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
	}}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	meter.RefreshBalance(context.Background(), "user_1")
	if len(meter.queue) != 1 {
		t.Fatalf("应排一次余额查询，实际 %d", len(meter.queue))
	}
	next := <-meter.queue
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
	meter.RefreshBalance(context.Background(), "user_1")
	meter.RefreshBalance(context.Background(), "user_1")
	meter.RefreshBalance(context.Background(), "user_2")
	if len(meter.queue) != 2 {
		t.Fatalf("同一账号的重复查询应合并，实际队列 %d", len(meter.queue))
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
