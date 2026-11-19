package pg

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

// TestPostgresQuotaReserveAndSettle 核对额度预留、截断、结算与覆盖额度落库，
// 以及实例用量按天汇总、另一个自然日独立计算。
func TestPostgresQuotaReserveAndSettle(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, id := range []string{"u1", "u2"} {
		if err := st.CreateUser(ctx, auth.User{ID: id, Email: id + "@b.cn", PasswordHash: "h"}); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	// 实例预算为 0 表示不限制，先只验账号额度。
	st.SetQuotaLimits(100, 200, 0)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, 40); err != nil || got != 40 {
		t.Fatalf("第一次预留应为 40，得到 %d %v", got, err)
	}
	// 只剩 60：预留按剩余量截断，调用方照常转发。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, 100); err != nil || got != 60 {
		t.Fatalf("剩余 60 时应截断为 60，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("额度用完应返回 ErrQuotaExceeded，得到 %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 100 {
		t.Fatalf("预留之后用量应为 100，得到 %d %v", used, err)
	}

	// 实际用量超过预留时补记差额，少于预留时退回。
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, 60, 90); err != nil {
		t.Fatalf("settle 补记: %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 130 {
		t.Fatalf("实际超过预留后用量应为 130，得到 %d %v", used, err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, 40, 10); err != nil {
		t.Fatalf("settle 退回: %v", err)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 100 {
		t.Fatalf("退回之后用量应为 100，得到 %d %v", used, err)
	}

	// llm_quota 的覆盖额度优先于配置的默认值。
	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_quota (user_id, daily_tokens, note) VALUES ('u2', 5000, '测试')`); err != nil {
		t.Fatalf("insert override: %v", err)
	}
	if got, err := st.Reserve(ctx, "u2", day, llmproxy.KindChat, 1000); err != nil || got != 1000 {
		t.Fatalf("覆盖额度应允许预留 1000，得到 %d %v", got, err)
	}

	// 自然日互不影响。
	if got, err := st.Reserve(ctx, "u1", "2026-11-19", llmproxy.KindChat, 80); err != nil || got != 80 {
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
		if err := st.CreateUser(ctx, auth.User{ID: id, Email: id + "@b.cn", PasswordHash: "h"}); err != nil {
			t.Fatalf("user %s: %v", id, err)
		}
	}
	st.SetQuotaLimits(1000, 200, 250)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, 200); err != nil || got != 200 {
		t.Fatalf("第一次预留应为 200，得到 %d %v", got, err)
	}
	// 实例只剩 50，账号额度还很宽。
	if got, err := st.Reserve(ctx, "u2", day, llmproxy.KindEmbedding, 100); err != nil || got != 50 {
		t.Fatalf("实例只剩 50 时应截断为 50，得到 %d %v", got, err)
	}
	if _, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, 1); !errors.Is(err, llmproxy.ErrQuotaExceeded) {
		t.Fatalf("实例预算用完应返回 ErrQuotaExceeded，得到 %v", err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 250 {
		t.Fatalf("实例用量应为 250，得到 %d %v", used, err)
	}

	// 结算退回 30，实例预算重新有 30 可用。
	if err := st.Settle(ctx, "u2", day, llmproxy.KindEmbedding, 50, 20); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if used, err := st.InstanceUsed(ctx, day); err != nil || used != 220 {
		t.Fatalf("退回之后实例用量应为 220，得到 %d %v", used, err)
	}
	if got, err := st.Reserve(ctx, "u2", day, llmproxy.KindEmbedding, 100); err != nil || got != 30 {
		t.Fatalf("退回之后应能再预留 30，得到 %d %v", got, err)
	}
}

// TestPostgresQuotaReserveIsAtomic 核对同一天的并发预留不会各自按旧用量通过：
// 10 个并发请求各要 20，总预算 100，正好 5 个成功，其余返回 ErrQuotaExceeded。
func TestPostgresQuotaReserveIsAtomic(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := st.CreateUser(ctx, auth.User{ID: "u1", Email: "atomic@b.cn", PasswordHash: "h"}); err != nil {
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
			got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, 20)
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
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 100 {
		t.Fatalf("预留之后用量应为 100，得到 %d %v", used, err)
	}
}
