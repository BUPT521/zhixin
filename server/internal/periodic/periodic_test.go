package periodic

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestRunRunsOnceImmediately(t *testing.T) {
	var calls atomic.Int64
	Run(context.Background(), 0, func() { calls.Add(1) })
	if got := calls.Load(); got != 1 {
		t.Fatalf("every 为 0 时只跑启动那一次，实际跑了 %d 次", got)
	}
}

func TestRunRepeatsUntilContextEnds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var calls atomic.Int64
	done := make(chan struct{})
	go func() {
		Run(ctx, time.Millisecond, func() { calls.Add(1) })
		close(done)
	}()
	// 等到至少跑到第三次，再取消，确认循环会退出。
	for calls.Load() < 3 {
		time.Sleep(time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ctx 结束之后循环没有退出")
	}
	if got := calls.Load(); got < 3 {
		t.Fatalf("循环应当重复执行，实际跑了 %d 次", got)
	}
}
