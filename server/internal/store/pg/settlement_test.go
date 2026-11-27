package pg

import (
	"context"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

// TestPostgresQuotaSettleFailureIsCompensated 核对结算失败之后预留不会一直占着当天
// 的额度：失败当场记一条待补偿记录并补退，补退没赶上的记录也会在下一次预留之前
// 退掉，用户不会因为上一次结算失败而继续收到 429（ADR-0086）。
func TestPostgresQuotaSettleFailureIsCompensated(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "settle@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	st.SetQuotaLimits(1000, 0)
	const day = "2026-11-18"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 600); err != nil || got != 600 {
		t.Fatalf("第一次预留应为 600，得到 %d %v", got, err)
	}
	// 取消的上下文让结算在事务开始之前就失败，与请求超时属于同一种失败。
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if err := st.Settle(canceled, "u1", day, llmproxy.KindChat, "", 600, 120, llmproxy.Usage{}, llmproxy.SettleAttempt{Attempts: 1}); err == nil {
		t.Fatal("取消的上下文应让结算失败")
	}
	// 失败当场补退：预留回到 0，用量不记，待补偿记录也处理掉了。
	if reserved := reservedTokens(t, st, "u1", day); reserved != 0 {
		t.Fatalf("结算失败之后预留应退回，得到 %d", reserved)
	}
	if used, err := st.Used(ctx, "u1", day, llmproxy.KindChat); err != nil || used != 0 {
		t.Fatalf("失败的结算不记用量，得到 %d %v", used, err)
	}
	if rows := settlementFailureRows(t, st); rows != 0 {
		t.Fatalf("补退之后不应留下待补偿记录，得到 %d 条", rows)
	}

	// 模拟上一次进程留下的记录：预留还在，补退那一步没有走到。额度只剩 400，
	// 不在预留之前补退的话 900 会被拒。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 600); err != nil || got != 600 {
		t.Fatalf("第二次预留应为 600，得到 %d %v", got, err)
	}
	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_settlement_failure (user_id, day, kind, reserved_tokens, billed_tokens)
		VALUES ('u1', $1::date, 'chat', 600, 90)`, day); err != nil {
		t.Fatalf("记待补偿: %v", err)
	}
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 900); err != nil || got != 900 {
		t.Fatalf("补退遗留下来的预留之后应能预留 900，得到 %d %v", got, err)
	}
	if rows := settlementFailureRows(t, st); rows != 0 {
		t.Fatalf("补退之后记录应删除，得到 %d 条", rows)
	}
}

// TestPostgresSettlementFailureSweepAndStaleReservations 核对全局补查与过期清理：
// 超过宽限期的待补偿记录会被补退并删除，两天之前的在途预留会被清掉，当天的不动
// （ADR-0086）。
func TestPostgresSettlementFailureSweepAndStaleReservations(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "sweep@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	st.SetQuotaLimits(1000, 0)
	const day = "2026-11-18"
	const staleDay = "2026-11-10"

	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 300); err != nil || got != 300 {
		t.Fatalf("当天预留应为 300，得到 %d %v", got, err)
	}
	if got, err := st.Reserve(ctx, "u1", staleDay, llmproxy.KindChat, "", 200); err != nil || got != 200 {
		t.Fatalf("过期那天的预留应为 200，得到 %d %v", got, err)
	}

	// 两天之前的预留清掉，当天的保留。
	cleared, err := st.ClearReservationsBefore(ctx, time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC))
	if err != nil || cleared != 1 {
		t.Fatalf("应清掉一行过期预留，得到 %d %v", cleared, err)
	}
	if reserved := reservedTokens(t, st, "u1", staleDay); reserved != 0 {
		t.Fatalf("过期那天的预留应清掉，得到 %d", reserved)
	}
	if reserved := reservedTokens(t, st, "u1", day); reserved != 300 {
		t.Fatalf("当天的预留在清理时不应受影响，得到 %d", reserved)
	}

	// 两条待补偿记录：一条已经过了宽限期，一条是刚刚写下的。
	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_settlement_failure
		(user_id, day, kind, reserved_tokens, billed_tokens, created_at)
		VALUES ('u1', $1::date, 'chat', 300, 50, now() - interval '10 minutes'),
		       ('u1', $1::date, 'chat', 1, 0, now())`, day); err != nil {
		t.Fatalf("记待补偿: %v", err)
	}
	count, err := st.SweepSettlementFailures(ctx, time.Now().Add(-time.Minute), 10)
	if err != nil || count != 1 {
		t.Fatalf("补查应处理一条过了宽限期的记录，得到 %d %v", count, err)
	}
	if reserved := reservedTokens(t, st, "u1", day); reserved != 0 {
		t.Fatalf("补查之后预留应退回，得到 %d", reserved)
	}
	if rows := settlementFailureRows(t, st); rows != 1 {
		t.Fatalf("刚写下的记录应留给下一轮，得到 %d 条", rows)
	}
}

// reservedTokens 返回一个账号当天在途预留的合计，用来核对退预留有没有真的落到
// llm_usage 上。
func reservedTokens(t *testing.T, st *Store, userID, day string) int64 {
	t.Helper()
	var reserved int64
	err := st.pool.QueryRow(context.Background(), `SELECT COALESCE(SUM(reserved_tokens + embedding_reserved_tokens), 0)
		FROM llm_usage WHERE user_id = $1 AND day = $2::date`, userID, day).Scan(&reserved)
	if err != nil {
		t.Fatalf("查在途预留: %v", err)
	}
	return reserved
}

// settlementFailureRows 返回待补偿记录的条数。
func settlementFailureRows(t *testing.T, st *Store) int64 {
	t.Helper()
	var rows int64
	if err := st.pool.QueryRow(context.Background(), `SELECT count(*) FROM llm_settlement_failure`).Scan(&rows); err != nil {
		t.Fatalf("查待补偿记录: %v", err)
	}
	return rows
}
