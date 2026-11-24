package llmproxy

import (
	"context"
	"errors"
	"testing"
)

// TestMemoryQuotaReserveSettle 核对内存额度的预留、截断、结算与覆盖额度：预留
// 按账号剩余与实例剩余取较小值，结算多退少补，额度用完返回 ErrQuotaExceeded。
func TestMemoryQuotaReserveSettle(t *testing.T) {
	ctx := context.Background()
	q := NewMemoryQuota()
	// 实例预算为 0 表示不限制，先只验账号额度。
	q.SetQuotaLimits(100, 200, 0)
	const day = "2026-11-18"

	if got, err := q.Reserve(ctx, "u1", day, KindChat, "", 40); err != nil || got != 40 {
		t.Fatalf("第一次预留应为 40，得到 %d %v", got, err)
	}
	// 只剩 60：预留按剩余量截断，调用方照常转发。
	if got, err := q.Reserve(ctx, "u1", day, KindChat, "", 100); err != nil || got != 60 {
		t.Fatalf("剩余 60 时应截断为 60，得到 %d %v", got, err)
	}
	if _, err := q.Reserve(ctx, "u1", day, KindChat, "", 1); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("额度用完应返回 ErrQuotaExceeded，得到 %v", err)
	}
	if used, _ := q.Used(ctx, "u1", day, KindChat); used != 100 {
		t.Fatalf("预留之后用量应为 100，得到 %d", used)
	}
	// 剩余量与请求量分开比较：剩余 60 时请求 40 应当拿满 40，而不是被截成 0。
	q2 := NewMemoryQuota()
	q2.SetQuotaLimits(100, 200, 0)
	if got, err := q2.Reserve(ctx, "u2", day, KindChat, "", 70); err != nil || got != 70 {
		t.Fatalf("第一次预留应为 70，得到 %d %v", got, err)
	}
	if got, err := q2.Reserve(ctx, "u2", day, KindChat, "", 40); err != nil || got != 30 {
		t.Fatalf("剩余 30 时应截断为 30，得到 %d %v", got, err)
	}

	// 实际用量超过预留时补记差额，少于预留时退回。
	if err := q.Settle(ctx, "u1", day, KindChat, "", 60, 90); err != nil {
		t.Fatalf("settle 补记: %v", err)
	}
	if used, _ := q.Used(ctx, "u1", day, KindChat); used != 130 {
		t.Fatalf("实际超过预留后用量应为 130，得到 %d", used)
	}
	if err := q.Settle(ctx, "u1", day, KindChat, "", 40, 10); err != nil {
		t.Fatalf("settle 退回: %v", err)
	}
	if used, _ := q.Used(ctx, "u1", day, KindChat); used != 100 {
		t.Fatalf("退回之后用量应为 100，得到 %d", used)
	}

	// 覆盖额度优先于配置的默认值。
	q.SetDailyLimit("u2", 500)
	if got, err := q.Reserve(ctx, "u2", day, KindChat, "", 300); err != nil || got != 300 {
		t.Fatalf("覆盖额度应允许预留 300，得到 %d %v", got, err)
	}
	if used, _ := q.InstanceUsed(ctx, day); used != 400 {
		t.Fatalf("实例用量应为两个账号合计 400，得到 %d", used)
	}

	// 自然日互不影响。
	if got, err := q.Reserve(ctx, "u1", "2026-11-19", KindChat, "", 80); err != nil || got != 80 {
		t.Fatalf("另一个自然日应独立计额度，得到 %d %v", got, err)
	}

	// 没有预留行时结算异常参数不会写出负用量。
	if err := q.Settle(ctx, "u3", day, KindChat, "", 5, 0); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if used, _ := q.Used(ctx, "u3", day, KindChat); used != 0 {
		t.Fatalf("用量不应为负，得到 %d", used)
	}
}

// TestMemoryQuotaInstanceLedgerSurvivesDelete 核对实例账本与账号用量分开：删号
// 清掉账号当天的用量，实例当天的预算不因此重新腾出来（ADR-0036）。
func TestMemoryQuotaInstanceLedgerSurvivesDelete(t *testing.T) {
	ctx := context.Background()
	q := NewMemoryQuota()
	q.SetQuotaLimits(1000, 200, 300)
	const day = "2026-11-18"

	if got, err := q.Reserve(ctx, "u1", day, KindChat, "", 300); err != nil || got != 300 {
		t.Fatalf("第一次预留应为 300，得到 %d %v", got, err)
	}
	if err := q.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("删除账号: %v", err)
	}
	if used, _ := q.Used(ctx, "u1", day, KindChat); used != 0 {
		t.Fatalf("删号之后账号用量应为 0，得到 %d", used)
	}
	if used, _ := q.InstanceUsed(ctx, day); used != 300 {
		t.Fatalf("删号不应减少实例用量，仍应为 300，得到 %d", used)
	}
	if _, err := q.Reserve(ctx, "u2", day, KindChat, "", 1); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("实例预算已被占满，应返回 ErrQuotaExceeded，得到 %v", err)
	}
}

// TestMemoryQuotaInstanceBudget 核对实例预算：所有账号的合计达到上限之后，
// 任何账号都预留不到，结算退回的部分重新变成可用预算。
func TestMemoryQuotaInstanceBudget(t *testing.T) {
	ctx := context.Background()
	q := NewMemoryQuota()
	q.SetQuotaLimits(1000, 200, 250)
	const day = "2026-11-18"

	if got, err := q.Reserve(ctx, "u1", day, KindChat, "", 200); err != nil || got != 200 {
		t.Fatalf("第一次预留应为 200，得到 %d %v", got, err)
	}
	// 实例只剩 50，账号额度还很宽。
	if got, err := q.Reserve(ctx, "u2", day, KindEmbedding, "", 100); err != nil || got != 50 {
		t.Fatalf("实例只剩 50 时应截断为 50，得到 %d %v", got, err)
	}
	if _, err := q.Reserve(ctx, "u1", day, KindChat, "", 1); !errors.Is(err, ErrQuotaExceeded) {
		t.Fatalf("实例预算用完应返回 ErrQuotaExceeded，得到 %v", err)
	}
	if used, _ := q.InstanceUsed(ctx, day); used != 250 {
		t.Fatalf("实例用量应为 250，得到 %d", used)
	}

	// 结算退回 30，实例预算重新有 30 可用。
	if err := q.Settle(ctx, "u2", day, KindEmbedding, "", 50, 20); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if used, _ := q.InstanceUsed(ctx, day); used != 220 {
		t.Fatalf("退回之后实例用量应为 220，得到 %d", used)
	}
	if got, err := q.Reserve(ctx, "u2", day, KindEmbedding, "", 100); err != nil || got != 30 {
		t.Fatalf("退回之后应能再预留 30，得到 %d %v", got, err)
	}
}

// TestMemoryQuotaAttributesUsageToKey 核对用量按模型代理密钥分开记、额度仍按账号
// 合计：两把密钥各占一行，用访问令牌的调用记在空编号那一行（ADR-0063）。
func TestMemoryQuotaAttributesUsageToKey(t *testing.T) {
	ctx := context.Background()
	q := NewMemoryQuota()
	q.SetQuotaLimits(1000, 2000, 0)
	const day = "2026-11-18"
	for _, call := range []struct {
		keyID string
		want  int64
	}{
		{keyID: "key-a", want: 100},
		{keyID: "key-b", want: 50},
		{keyID: "", want: 20},
	} {
		if got, err := q.Reserve(ctx, "u1", day, KindChat, call.keyID, call.want); err != nil || got != call.want {
			t.Fatalf("密钥 %q 预留应为 %d，得到 %d %v", call.keyID, call.want, got, err)
		}
	}
	q.mu.Lock()
	byKey := map[string]int64{}
	for key, tokens := range q.used {
		if key[0] == "u1" && key[1] == day && key[2] == string(KindChat) {
			byKey[key[3]] = tokens
		}
	}
	q.mu.Unlock()
	if byKey["key-a"] != 100 || byKey["key-b"] != 50 || byKey[""] != 20 {
		t.Fatalf("用量应按密钥分开记，得到 %+v", byKey)
	}
	if used, _ := q.Used(ctx, "u1", day, KindChat); used != 170 {
		t.Fatalf("账号合计应为 170，得到 %d", used)
	}
}
