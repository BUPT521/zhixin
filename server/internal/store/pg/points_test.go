package pg

import (
	"math"
	"testing"
)

func TestPointBudgetFor(t *testing.T) {
	const perPoint = 1000
	for _, tc := range []struct {
		name                    string
		applied, balance, usage int64
		wantPoints, wantTokens  int64
	}{
		{"整积分余额", 0, 5, 0, 5, 5000},
		{"不足一分的用量占用一分余额", 0, 1, 400, 0, 600},
		{"已核销积分当天剩余的覆盖量", 1, 0, 400, 0, 600},
		{"已核销余量与未占用整积分并存", 1, 1, 400, 1, 1600},
		{"截断核销后余额不足以覆盖用量", 1, 1, 3000, 0, 0},
		{"实际容量超出计数上限", 1, math.MaxInt64, 400, math.MaxInt64, math.MaxInt64},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ledger := pointLedger{applied: tc.applied, balance: tc.balance}
			budget := pointBudgetFor(tc.usage, ledger.applied, ledger.available(), perPoint)
			if budget.Points != tc.wantPoints || budget.Tokens != tc.wantTokens {
				t.Fatalf("可用量为 %d 积分、%d token，应为 %d 积分、%d token",
					budget.Points, budget.Tokens, tc.wantPoints, tc.wantTokens)
			}
		})
	}
}

// TestPointBudgetForDue 守住扣减口径与展示口径来自同一段换算：应申请积分是当天
// 尚未申请的差额，按可用积分截断，副本未知时按差额整额申请（ADR-0073）。
func TestPointBudgetForDue(t *testing.T) {
	cases := []struct {
		name                      string
		usage, applied, available int64
		want                      int64
	}{
		{"副本小于应扣时只申请副本", 20000, 0, 5, 5},
		{"待确认的核销占用可用积分", 20000, 2, 3, 3},
		{"已申请超过可用积分时仍申请剩余差额", 10000, 4, 1, 1},
		{"成功并已反映的核销不再从可用积分里减", 150000, 40, 100, 100},
		{"可用积分为零时不申请", 20000, 5, 0, 0},
		{"副本未知时只申请差额", 150000, 40, -1, 110},
		{"当天已经申请够时不申请", 20000, 20, 5, 0},
		{"已申请超过应扣时不申请", 20000, 25, 5, 0},
	}
	for _, c := range cases {
		if got := pointBudgetFor(c.usage, c.applied, c.available, 1000).Due; got != c.want {
			t.Errorf("%s: 应申请 %d，得到 %d", c.name, c.want, got)
		}
	}
}
