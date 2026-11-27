package pg

import (
	"math"
	"testing"
)

func TestPointLedgerAvailability(t *testing.T) {
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
			ledger := pointLedger{applied: tc.applied, balancePoints: tc.balance}
			points, tokens := ledger.availability(tc.usage, perPoint)
			if points != tc.wantPoints || tokens != tc.wantTokens {
				t.Fatalf("可用量为 %d 积分、%d token，应为 %d 积分、%d token", points, tokens, tc.wantPoints, tc.wantTokens)
			}
		})
	}
}
