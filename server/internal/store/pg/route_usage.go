package pg

import (
	"context"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

var _ llmproxy.UsageStore = (*Store)(nil)

func (s *Store) AddRouteUsage(ctx context.Context, row llmproxy.RouteUsage) error {
	day, err := pgDate(row.Day)
	if err != nil {
		return err
	}
	return s.q.AddRouteUsage(ctx, db.AddRouteUsageParams{
		Day: day, Kind: string(row.Kind), Model: row.Model, ProviderID: row.ProviderID,
		UpstreamModel: row.UpstreamModel, Attempts: row.Attempts, FirstAttempts: row.FirstAttempts,
		FailoverAttempts: row.FailoverAttempts, Successes: row.Successes,
		TruncatedAttempts: row.TruncatedAttempts, CanceledAttempts: row.CanceledAttempts,
		Tokens: row.Tokens, EstimatedTokens: row.EstimatedTokens,
	})
}

func (s *Store) RouteUsage(ctx context.Context, from, to string) ([]llmproxy.RouteUsage, error) {
	start, err := pgDate(from)
	if err != nil {
		return nil, err
	}
	end, err := pgDate(to)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListRouteUsage(ctx, db.ListRouteUsageParams{FromDay: start, ToDay: end})
	if err != nil {
		return nil, err
	}
	out := make([]llmproxy.RouteUsage, 0, len(rows))
	for _, row := range rows {
		out = append(out, llmproxy.RouteUsage{
			Day: row.Day.Time.Format("2006-01-02"),
			RouteUsageKey: llmproxy.RouteUsageKey{
				Kind: llmproxy.Kind(row.Kind), Model: row.Model, ProviderID: row.ProviderID, UpstreamModel: row.UpstreamModel,
			},
			UsageCounts: llmproxy.UsageCounts{
				Attempts: row.Attempts, FirstAttempts: row.FirstAttempts, FailoverAttempts: row.FailoverAttempts,
				TruncatedAttempts: row.TruncatedAttempts, CanceledAttempts: row.CanceledAttempts,
				Successes: row.Successes, Tokens: row.Tokens, EstimatedTokens: row.EstimatedTokens,
			},
		})
	}
	return out, nil
}
