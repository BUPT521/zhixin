package pg

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

// TestPostgresQuotaReserveAndSettle 核对额度预留、结算与覆盖额度落库，以及实例
// 用量按天汇总、另一个自然日独立计算。预留要么拿满、要么返回带原因的错误；额度
// 判定看已结算与在途预留之和，展示只看已结算量（ADR-0071）。
func TestPostgresQuotaReserveAndSettle(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, id := range []string{"u1", "u2"} {
		if err := createAccount(ctx, st, auth.User{ID: id, PasswordHash: "h"}, id+"@b.cn"); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	// 实例预算为 0 表示不限制，先只验账号额度。
	st.SetQuotaLimits(100, 200, 0)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 40); err != nil || got != 40 {
		t.Fatalf("第一次预留应为 40，得到 %d %v", got, err)
	}
	// 只剩 60：请求 100 拿不到整份，返回账号额度原因，也不写入预留。
	var quota *llmproxy.QuotaExceededError
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); !errors.As(err, &quota) || quota.Reason != llmproxy.QuotaReasonAccount {
		t.Fatalf("剩余 60 时请求 100 应返回 account，得到 %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 0 {
		t.Fatalf("在途预留不算已结算用量，展示应为 0，得到 %d %v", used, err)
	}
	// 拿满剩余 60，账号额度占满。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 60); err != nil || got != 60 {
		t.Fatalf("剩余 60 时请求 60 应拿满，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("额度用完应返回 ErrQuotaExceeded，得到 %v", err)
	}

	// 结算把预留转成已结算用量：对外的用量这时才增加，多退少补。
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 60, 90, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle 补记: %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 90 {
		t.Fatalf("实际超过预留后已结算用量应为 90，得到 %d %v", used, err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 40, 10, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle 退回: %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 100 {
		t.Fatalf("退回之后已结算用量应为 100，得到 %d %v", used, err)
	}

	// llm_quota 的覆盖额度优先于配置的默认值。
	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_quota (user_id, daily_tokens, note) VALUES ('u2', 5000, '测试')`); err != nil {
		t.Fatalf("insert override: %v", err)
	}
	if got, err := st.Reserve(ctx, "u2", day, llmproxy.KindChat, "", 1000); err != nil || got != 1000 {
		t.Fatalf("覆盖额度应允许预留 1000，得到 %d %v", got, err)
	}

	// 自然日互不影响。
	if got, err := st.Reserve(ctx, "u1", "2026-11-19", llmproxy.KindChat, "", 80); err != nil || got != 80 {
		t.Fatalf("另一个自然日应独立计额度，得到 %d %v", got, err)
	}

	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 1100 {
		t.Fatalf("实例用量应为两个账号合计 1100，得到 %d %v", used, err)
	}
}

// TestPostgresQuotaInstanceBudget 核对实例预算：所有账号的合计达到上限之后任何
// 账号都预留不到，结算退回的部分重新变成可用预算。
func TestPostgresQuotaInstanceBudget(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, id := range []string{"u1", "u2"} {
		if err := createAccount(ctx, st, auth.User{ID: id, PasswordHash: "h"}, id+"@b.cn"); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	st.SetQuotaLimits(1000, 200, 250)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 200); err != nil || got != 200 {
		t.Fatalf("第一次预留应为 200，得到 %d %v", got, err)
	}
	// 实例只剩 50：放不下整份 100，返回实例预算原因，也不写入预留。
	var quota *llmproxy.QuotaExceededError
	if _, err := st.Reserve(ctx, "u2", day, llmproxy.KindEmbedding, "", 100); !errors.As(err, &quota) || quota.Reason != llmproxy.QuotaReasonInstance {
		t.Fatalf("实例只剩 50 时应返回 instance，得到 %v", err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 200 {
		t.Fatalf("只有成功的那笔进实例账本，应为 200，得到 %d %v", used, err)
	}
	// 再占满剩下的 50，实例预算用完之后谁都预留不到。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 50); err != nil || got != 50 {
		t.Fatalf("实例还剩 50 时应能预留 50，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("实例预算用完应返回 ErrQuotaExceeded，得到 %v", err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 250 {
		t.Fatalf("实例用量应为 250，得到 %d %v", used, err)
	}

	// 结算退回 30，实例预算重新有 30 可用。
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 200, 170, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 50, 50, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 220 {
		t.Fatalf("退回之后实例用量应为 220，得到 %d %v", used, err)
	}
	if got, err := st.Reserve(ctx, "u2", day, llmproxy.KindEmbedding, "", 30); err != nil || got != 30 {
		t.Fatalf("退回之后应能再预留 30，得到 %d %v", got, err)
	}
}

// TestPostgresQuotaInstanceLedgerSurvivesDelete 核对实例账本不随账号删除减少：删号
// 级联删掉账号当天的用量行，实例当天的预算仍然按已经发生的用量计算（ADR-0036）。
func TestPostgresQuotaInstanceLedgerSurvivesDelete(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, id := range []string{"u1", "u2"} {
		if err := createAccount(ctx, st, auth.User{ID: id, PasswordHash: "h"}, id+"@b.cn"); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	st.SetQuotaLimits(1000, 200, 300)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 300); err != nil || got != 300 {
		t.Fatalf("第一次预留应为 300，得到 %d %v", got, err)
	}
	if err := st.DeleteUser(ctx, "u1"); err != nil {
		t.Fatalf("删除账号: %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 0 {
		t.Fatalf("删号之后账号用量应为 0，得到 %d %v", used, err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 300 {
		t.Fatalf("删号不应减少实例用量，仍应为 300，得到 %d %v", used, err)
	}
	if _, err := st.Reserve(ctx, "u2", day, llmproxy.KindChat, "", 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("实例预算已被占满，应返回 ErrQuotaExceeded，得到 %v", err)
	}
}

// TestPostgresQuotaReserveIsAtomic 核对同一天的并发预留不会各自按旧用量通过：
// 10 个并发请求各要 20，总预算 100，正好 5 个成功，其余返回 ErrQuotaExceeded。
func TestPostgresQuotaReserveIsAtomic(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "atomic@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	st.SetQuotaLimits(100, 200, 0)
	const day = "2026-11-18"

	var wg sync.WaitGroup
	var mu sync.Mutex
	var reserved int64
	var exceeded, other int
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 20)
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				reserved += got
			case errors.Is(err, llmproxy.ErrQuotaExceeded):
				exceeded++
			default:
				other++
			}
		}()
	}
	wg.Wait()
	if other != 0 {
		t.Fatalf("并发预留不应出现其他错误，得到 %d 个", other)
	}
	if exceeded != 5 {
		t.Fatalf("总预算 100 时应有 5 个请求被拒，得到 %d 个", exceeded)
	}
	if reserved != 100 {
		t.Fatalf("成功的预留应合计 100，得到 %d", reserved)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 0 {
		t.Fatalf("在途预留不算已结算用量，展示应为 0，得到 %d %v", used, err)
	}
}

// TestPostgresQuotaInstanceCountsFreePortionOnly 核对实例账本只累计免费额度内的
// 部分：结算超出免费额度的用量由积分承担，不再占用实例预算（ADR-0070）。
func TestPostgresQuotaInstanceCountsFreePortionOnly(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "free@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	st.SetQuotaLimits(100, 200, 1000)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("第一次预留应为 100，得到 %d %v", got, err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 100, 250, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 250 {
		t.Fatalf("账号用量应为 250，得到 %d %v", used, err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 100 {
		t.Fatalf("实例账本只应记免费额度内的 100，得到 %d %v", used, err)
	}
}

// TestPostgresQuotaAttributesUsageToKey 核实用量行按模型代理密钥分开记，账号合计
// 仍是各行之和，用访问令牌的调用记空字符串，结算落到同一把密钥那一行（ADR-0063）。
func TestPostgresQuotaAttributesUsageToKey(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "attr@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	st.SetQuotaLimits(1000, 2000, 0)
	const day = "2026-11-18"
	for _, call := range []struct {
		keyID string
		want  int64
	}{
		{keyID: "key-a", want: 100},
		{keyID: "key-b", want: 50},
		{keyID: "", want: 20},
	} {
		if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, call.keyID, call.want); err != nil || got != call.want {
			t.Fatalf("密钥 %q 预留应为 %d，得到 %d %v", call.keyID, call.want, got, err)
		}
	}
	rows, err := st.pool.Query(ctx, "SELECT api_key_id, tokens, reserved_tokens FROM llm_usage WHERE user_id = 'u1' ORDER BY api_key_id")
	if err != nil {
		t.Fatalf("query usage: %v", err)
	}
	defer rows.Close()
	byKey := map[string]int64{}
	reservedByKey := map[string]int64{}
	for rows.Next() {
		var keyID string
		var tokens, reserved int64
		if err := rows.Scan(&keyID, &tokens, &reserved); err != nil {
			t.Fatalf("scan usage: %v", err)
		}
		byKey[keyID] = tokens
		reservedByKey[keyID] = reserved
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows: %v", err)
	}
	rows.Close()
	if len(byKey) != 3 || reservedByKey["key-a"] != 100 || reservedByKey["key-b"] != 50 || reservedByKey[""] != 20 {
		t.Fatalf("在途预留应按密钥分开记，得到 %+v", reservedByKey)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 0 {
		t.Fatalf("在途预留不算已结算用量，展示应为 0，得到 %d %v", used, err)
	}

	// 结算落到这次预留所用的密钥那一行，在途预留随之清掉。
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "key-a", 100, 130, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	var tokens, reserved int64
	if err := st.pool.QueryRow(ctx, "SELECT tokens, reserved_tokens FROM llm_usage WHERE user_id = 'u1' AND api_key_id = 'key-a'").Scan(&tokens, &reserved); err != nil {
		t.Fatalf("query settled row: %v", err)
	}
	if tokens != 130 || reserved != 0 {
		t.Fatalf("结算之后 key-a 应为 130 且没有在途预留，得到 tokens=%d reserved=%d", tokens, reserved)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 130 {
		t.Fatalf("结算之后账号合计应为 130，得到 %d %v", used, err)
	}
}
