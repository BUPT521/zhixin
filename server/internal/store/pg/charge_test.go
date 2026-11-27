package pg

import (
	"context"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/nowpay"
)

// TestPostgresPendingChargeIsSwept 核对结算提交之后申请核销的缺口：进程在两步之间
// 退出时留下一条待办，补查按这一天的用量重新申请；已经收齐的待办只删除，不再申请
// 一次；超过保留期还没有收齐的待办删掉并记日志（ADR-0087）。
func TestPostgresPendingChargeIsSwept(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "u1@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	const day = "2026-11-25"
	const free = "2026-11-24"
	// drop 模拟进程在结算提交之后、申请核销之前退出：这一步按下了，流水一条也没有。
	recorder := &fakeRecorder{perPoint: 1000, drop: true}
	enablePaidQuota(t, st)
	st.SetNowPay(recorder)
	st.SetQuotaLimits(100, 0)
	if err := st.SaveBalance(ctx, "u1", 5, time.Now()); err != nil {
		t.Fatalf("save balance: %v", err)
	}

	// 免费额度以内的结算不产生待办。
	if got, err := st.Reserve(ctx, "u1", free, llmproxy.KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("免费额度内的预留应为 100，得到 %d %v", got, err)
	}
	if err := st.Settle(ctx, "u1", free, llmproxy.KindChat, "", 100, 100, llmproxy.Usage{}, llmproxy.SettleAttempt{Attempts: 1}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if rows := pendingChargeRows(t, st); rows != 0 {
		t.Fatalf("免费额度内不应产生待办，得到 %d 条", rows)
	}

	// 实际用量 3,000、免费额度 100：超额的那 2,900 个计费 token 要靠申请核销收回。
	if got, err := st.Reserve(ctx, "u1", day, llmproxy.KindChat, "", 100); err != nil || got != 100 {
		t.Fatalf("预留应为 100，得到 %d %v", got, err)
	}
	if err := st.Settle(ctx, "u1", day, llmproxy.KindChat, "", 100, 3000, llmproxy.Usage{}, llmproxy.SettleAttempt{Attempts: 1}); err != nil {
		t.Fatalf("settle: %v", err)
	}
	if len(recorder.charged) != 0 {
		t.Fatalf("申请那一步被丢掉，不应有核销申请: %+v", recorder.charged)
	}
	if rows := pendingChargeRows(t, st); rows != 1 {
		t.Fatalf("结算之后应留下一条待办，得到 %d 条", rows)
	}

	// 补查按这一天的用量重新申请，取的是记在待办里的自然日，跨日也能补。
	recorder.drop = false
	count, err := st.SweepPendingCharges(ctx, time.Now().Add(time.Minute), 10)
	if err != nil || count != 1 {
		t.Fatalf("补查应处理一条待办，得到 %d %v", count, err)
	}
	if len(recorder.charged) != 1 || recorder.charged[0] != 2900 {
		t.Fatalf("补查应按 2,900 个计费 token 重新申请，得到 %+v", recorder.charged)
	}
	if len(recorder.chargedDays) != 1 || recorder.chargedDays[0] != day {
		t.Fatalf("补查应记在这一天，得到 %+v", recorder.chargedDays)
	}

	// 假执行器不写流水，待办还在；补上流水之后补查只删除待办，不再申请一次。
	if _, ok, err := st.ReservePoints(ctx, nowpay.Charge{ID: "nc_1", UserID: "u1", Day: day, Tokens: 2900}, 3); err != nil || !ok {
		t.Fatalf("写入核销流水: ok=%v err=%v", ok, err)
	}
	if _, err := st.SweepPendingCharges(ctx, time.Now().Add(time.Minute), 10); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if rows := pendingChargeRows(t, st); rows != 0 {
		t.Fatalf("收齐之后待办应删除，得到 %d 条", rows)
	}
	if len(recorder.charged) != 1 {
		t.Fatalf("已收齐的待办不应再申请一次，得到 %+v", recorder.charged)
	}

	// 超过保留期还没有收齐的待办不再重试，删掉之后留一条日志。
	if _, err := st.pool.Exec(ctx, `INSERT INTO llm_charge_pending (user_id, day, chargeable_tokens, created_at)
		VALUES ('u1', '2026-11-20', 5000, now() - interval '8 days')`); err != nil {
		t.Fatalf("insert stale pending charge: %v", err)
	}
	if _, err := st.SweepPendingCharges(ctx, time.Now().Add(time.Minute), 10); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if rows := pendingChargeRows(t, st); rows != 0 {
		t.Fatalf("过期的待办应删除，得到 %d 条", rows)
	}
	if len(recorder.charged) != 1 {
		t.Fatalf("过期的待办不应再申请，得到 %+v", recorder.charged)
	}
}

// pendingChargeRows 返回待申请核销的用量条数。
func pendingChargeRows(t *testing.T, st *Store) int64 {
	t.Helper()
	var rows int64
	if err := st.pool.QueryRow(context.Background(), `SELECT count(*) FROM llm_charge_pending`).Scan(&rows); err != nil {
		t.Fatalf("查待申请的核销用量: %v", err)
	}
	return rows
}
