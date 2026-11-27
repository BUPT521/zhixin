package feedback

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"
)

// newPruneService 固定“现在”，让保留期边界可复现：2026-11-18 往前 365 天是
// 2025-11-18。
func newPruneService(store Store) *Service {
	svc := NewService(store)
	svc.now = func() time.Time { return time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC) }
	return svc
}

func seedFeedback(t *testing.T, store *MemoryStore) {
	t.Helper()
	ctx := context.Background()
	items := []Item{
		{ID: "old", Content: "保留期之前的反馈", CreatedAt: time.Date(2025, 11, 1, 0, 0, 0, 0, time.UTC)},
		{ID: "edge", Content: "保留期起点当天的反馈", CreatedAt: time.Date(2025, 11, 18, 10, 0, 0, 0, time.UTC)},
		{ID: "fresh", Content: "保留期之内的反馈", CreatedAt: time.Date(2026, 11, 18, 0, 0, 0, 0, time.UTC)},
	}
	for _, item := range items {
		if err := store.CreateFeedback(ctx, item); err != nil {
			t.Fatalf("seed %s: %v", item.ID, err)
		}
	}
}

func TestPruneDeletesOnlyRowsOutsideKeepWindow(t *testing.T) {
	store := NewMemoryStore()
	svc := newPruneService(store)
	svc.SetKeepDays(365)
	seedFeedback(t, store)

	deleted, err := svc.Prune(context.Background())
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("应删除 1 行，得到 %d", deleted)
	}
	items := store.snapshot()
	if len(items) != 2 {
		t.Fatalf("应保留 2 行，得到 %d", len(items))
	}
	edgeKept := false
	for _, item := range items {
		if item.ID == "old" {
			t.Fatal("2025-11-01 的反馈应被删除")
		}
		if item.ID == "edge" {
			edgeKept = true
		}
	}
	// 保留期起点当天的反馈不删，边界与 retention 的清理口径一致。
	if !edgeKept {
		t.Fatalf("2025-11-18 的反馈应保留，得到 %+v", items)
	}
}

func TestPruneSkipsWhenKeepDaysIsZero(t *testing.T) {
	store := NewMemoryStore()
	svc := newPruneService(store)
	svc.SetKeepDays(0)
	seedFeedback(t, store)

	deleted, err := svc.Prune(context.Background())
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if deleted != 0 {
		t.Fatalf("保留天数设为 0 时不清理，得到删除 %d 行", deleted)
	}
	if got := len(store.snapshot()); got != 3 {
		t.Fatalf("应保留全部 3 行，得到 %d", got)
	}
}

// 保留天数只由配置层给出，业务层不再写一份与配置默认值相同的兜底：没有调用
// SetKeepDays 时不清理，装配处漏了这一步会立刻暴露，而不是悄悄沿用 365 天。
func TestPruneSkipsWithoutConfiguredKeepDays(t *testing.T) {
	store := NewMemoryStore()
	svc := newPruneService(store)
	seedFeedback(t, store)

	deleted, err := svc.Prune(context.Background())
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if deleted != 0 {
		t.Fatalf("未设置保留天数时不清理，得到删除 %d 行", deleted)
	}
	if got := len(store.snapshot()); got != 3 {
		t.Fatalf("应保留全部 3 行，得到 %d", got)
	}
}

func TestPruneLoopPrunesAtStartup(t *testing.T) {
	store := NewMemoryStore()
	svc := newPruneService(store)
	svc.SetKeepDays(365)
	seedFeedback(t, store)

	// ctx 已结束：PruneLoop 先清一次，再在第一个 select 返回，不进入每日循环。
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	svc.PruneLoop(ctx, log)

	items := store.snapshot()
	if len(items) != 2 {
		t.Fatalf("启动时应清掉保留期之外的一行，留下 2 行，得到 %d", len(items))
	}
}
