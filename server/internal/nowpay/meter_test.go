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

func TestRecordWithoutChargeableTokensDoesNothing(t *testing.T) {
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	meter.Record(context.Background(), "user_1", "2026-11-25", 0)
	meter.Record(context.Background(), "user_1", "2026-11-25", -10)
	if len(ledger.created) != 0 {
		t.Fatalf("没有超出免费额度的用量不该产生核销: %+v", ledger.created)
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
}

func TestProcessingIsQueriedWithTheSameRequestNo(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodVerify:  `{"code":"10000","consume_status":"PROCESSING","quota_unit":"POINT"}`,
		methodRefresh: `{"code":"10000","consume_status":"SUCCEEDED","consumed":3,"remaining":97}`,
	}}
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if got := ledger.last(); got.status != StatusProcessing {
		t.Fatalf("PROCESSING 应记为处理中: %+v", got)
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
	ledger := &fakeLedger{}
	meter := newTestMeter(t, ledger, caller)
	charge := Charge{ID: "nc_1", UserID: "user_1", Day: "2026-11-25", Points: 3, Status: StatusPending}
	meter.run(context.Background(), job{charge: charge, verify: true})
	if got := ledger.last(); got.status != StatusFailed {
		t.Fatalf("余额不足应记失败，让下次结算重算差额: %+v", got)
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
