package llmproxy

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// settleFailingQuota 让结算固定失败，用来核对 settle 不把错误就地吞掉。
type settleFailingQuota struct {
	QuotaStore
	err error
}

func (q settleFailingQuota) Settle(context.Context, string, string, Kind, string, int64, int64, Usage, SettleAttempt) error {
	return q.err
}

// TestSettleReturnsTheQuotaError 核对结算失败会交回调用方：由它连着请求号与用量写
// 日志，预留的补退与待补偿记录由额度实现负责（ADR-0086）。
func TestSettleReturnsTheQuotaError(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	router := NewRouter(NewMemoryCatalog(), secretbox.Random(), log)
	if err := router.Reload(context.Background()); err != nil {
		t.Fatalf("reload: %v", err)
	}
	want := errors.New("结算超时")
	quota := settleFailingQuota{QuotaStore: NewMemoryQuota(), err: want}
	p := NewRoutedHandler(baseConfig(), router, quota, quota, time.UTC, log)
	r := httptest.NewRequest(http.MethodPost, "/v1/llm/responses", nil)
	if err := p.settle(r, "u1", "2026-11-18", KindChat, "", 100, 50, Usage{}, attemptOf(false)); !errors.Is(err, want) {
		t.Fatalf("settle 应把额度实现的错误交回调用方，得到 %v", err)
	}
}
