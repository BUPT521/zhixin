package pg

import "testing"

func TestChargeableTokensKeepsTheFreeAllowanceFirst(t *testing.T) {
	for _, test := range []struct {
		name                    string
		used, limit, paid, want int64
	}{
		{"没有用量", 0, 200000, 0, 0},
		{"免费额度够用", 150000, 200000, 0, 0},
		{"刚好用完免费额度", 200000, 200000, 0, 0},
		{"超出免费额度", 250000, 200000, 0, 50000},
		{"遗留余额先承担", 250000, 200000, 50000, 0},
		{"遗留余额不够", 300000, 200000, 50000, 50000},
		{"遗留余额超过超出部分", 220000, 200000, 50000, 0},
		{"没有配置每日额度", 250000, 0, 0, 250000},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := chargeableTokens(test.used, test.limit, test.paid); got != test.want {
				t.Fatalf("chargeableTokens(%d, %d, %d) = %d，应为 %d",
					test.used, test.limit, test.paid, got, test.want)
			}
		})
	}
}
