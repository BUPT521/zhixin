package nowpay

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

// fakeMaintenance 记录补查与保留期的调用，并按预设的批次返回删除行数。
type fakeMaintenance struct {
	unsettled []Charge
	// purchaseBatches、chargeBatches 与 orphanBatches 依次作为每一批的删除行数返回，
	// 用完之后返回 0。
	purchaseBatches []int64
	chargeBatches   []int64
	orphanBatches   []int64
	pruneCalls      int
	orphanDeletes   int
	reconcileCalls  int
	instanceTokens  int64
	counts          map[string]int64
}

func (f *fakeMaintenance) UnsettledGlobal(context.Context, time.Time, int) ([]Charge, error) {
	return f.unsettled, nil
}

func (f *fakeMaintenance) DeleteExpiredPurchases(_ context.Context, _ time.Time, _ int) (int64, error) {
	f.pruneCalls++
	return popBatch(&f.purchaseBatches), nil
}

func (f *fakeMaintenance) DeleteTerminalCharges(_ context.Context, _ time.Time, _ int) (int64, error) {
	return popBatch(&f.chargeBatches), nil
}

func (f *fakeMaintenance) DeleteOrphanCharges(_ context.Context, _ time.Time, _ int) (int64, error) {
	f.orphanDeletes++
	return popBatch(&f.orphanBatches), nil
}

func (f *fakeMaintenance) ChargeStatusCounts(context.Context) (map[string]int64, error) {
	f.reconcileCalls++
	return f.counts, nil
}

func (f *fakeMaintenance) InstanceUsed(context.Context, string) (int64, error) {
	return f.instanceTokens, nil
}

func popBatch(batches *[]int64) int64 {
	if len(*batches) == 0 {
		return 0
	}
	next := (*batches)[0]
	*batches = (*batches)[1:]
	return next
}

// TestMaintenanceLoopReconcilesAndPrunesInBatches 守住每日维护：先记一次对账日志，再
// 按 1000 行一批删购买入口与终态流水，删满一批继续，不满一批就停；删号之后失去归属
// 的流水按同一批大小清理，它们再也补查不到结果。
func TestMaintenanceLoopReconcilesAndPrunesInBatches(t *testing.T) {
	store := &fakeMaintenance{
		purchaseBatches: []int64{1000, 10},
		chargeBatches:   []int64{3},
		orphanBatches:   []int64{1000},
		counts:          map[string]int64{StatusPending: 2, StatusSucceeded: 7},
		instanceTokens:  42,
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // 立刻结束，只跑启动那一次。
	MaintenanceLoop(ctx, store, log)
	if store.reconcileCalls != 1 {
		t.Fatalf("应在启动时记一次对账日志，实际 %d 次", store.reconcileCalls)
	}
	if store.pruneCalls != 2 {
		t.Fatalf("购买入口应删两批（第一批满 1000），实际 %d 批", store.pruneCalls)
	}
	if store.orphanDeletes != 2 {
		t.Fatalf("失去归属的流水应删两批（第一批满 1000），实际 %d 批", store.orphanDeletes)
	}
	if len(store.purchaseBatches) != 0 || len(store.chargeBatches) != 0 || len(store.orphanBatches) != 0 {
		t.Fatalf("应把预设批次用完: %v %v %v", store.purchaseBatches, store.chargeBatches, store.orphanBatches)
	}
}

// TestSweepLoopEnqueuesOldCharges 守住补查循环用的宽限期：把超过宽限期的流水排进
// 核销队列，处理中与待确认按各自的方式补查。
func TestSweepLoopEnqueuesOldCharges(t *testing.T) {
	store := &fakeMaintenance{unsettled: []Charge{
		{ID: "nc_1", UserID: "user_1", Points: 2, Status: StatusPending},
	}}
	ledger := &fakeLedger{unsettledGlobal: store.unsettled}
	meter := newTestMeter(t, ledger, &fakeCaller{})
	count, err := meter.Sweep(context.Background(), time.Now().Add(-sweepGrace), sweepBatch)
	if err != nil || count != 1 {
		t.Fatalf("应排进一条待核销流水: %d %v", count, err)
	}
	if next := <-meter.queue; !next.verify || next.charge.ID != "nc_1" {
		t.Fatalf("pending 流水应按原请求号重试核销: %+v", next)
	}
}
