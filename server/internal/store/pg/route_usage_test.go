package pg

import (
	"testing"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

func TestPostgresRouteUsageMergesAttempts(t *testing.T) {
	s := newTestStore(t)
	row := llmproxy.RouteUsage{
		Day: "2026-11-19",
		RouteUsageKey: llmproxy.RouteUsageKey{
			Kind: llmproxy.KindChat, Model: "chat-model", ProviderID: "example", UpstreamModel: "upstream",
		},
		UsageCounts: llmproxy.UsageCounts{Attempts: 1, FirstAttempts: 1, CanceledAttempts: 1, Tokens: 4, EstimatedTokens: 4},
	}
	for _, counts := range []llmproxy.UsageCounts{row.UsageCounts,
		{Attempts: 1, FailoverAttempts: 1, TruncatedAttempts: 1, Tokens: 12, InputTokens: 40, CachedTokens: 30},
		{Attempts: 1, FailoverAttempts: 1, Successes: 1, Tokens: 7, InputTokens: 60, CachedTokens: 45},
	} {
		row.UsageCounts = counts
		if err := s.AddRouteUsage(t.Context(), row); err != nil {
			t.Fatal(err)
		}
	}
	row.Day = "2026-11-18"
	if err := s.AddRouteUsage(t.Context(), row); err != nil {
		t.Fatal(err)
	}
	rows, err := s.RouteUsage(t.Context(), "2026-11-19", "2026-11-19")
	want := llmproxy.UsageCounts{
		Attempts: 3, FirstAttempts: 1, FailoverAttempts: 2, Successes: 1, TruncatedAttempts: 1,
		CanceledAttempts: 1, Tokens: 23, EstimatedTokens: 4, InputTokens: 100, CachedTokens: 75,
	}
	if err != nil || len(rows) != 1 || rows[0].UsageCounts != want || rows[0].RouteUsageKey != row.RouteUsageKey {
		t.Fatalf("usage = %+v, err = %v", rows, err)
	}
}
