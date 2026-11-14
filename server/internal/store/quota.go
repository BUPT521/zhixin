package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

type quota struct{ q *db.Queries }

func Quota(pool *pgxpool.Pool) llmproxy.Quota { return &quota{db.New(pool)} }

func calendarDay(day string) (pgtype.Date, error) {
	date, err := time.Parse(time.DateOnly, day)
	return pgtype.Date{Time: date, Valid: err == nil}, err
}

func (q *quota) Used(ctx context.Context, userID, day string) (int64, error) {
	date, err := calendarDay(day)
	if err != nil {
		return 0, err
	}
	total, err := q.q.UsedTokens(ctx, db.UsedTokensParams{UserID: userID, Day: date})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return total, err
}

func (q *quota) Add(ctx context.Context, userID, day string, tokens int64) error {
	date, err := calendarDay(day)
	if err != nil {
		return err
	}
	return q.q.AddTokens(ctx, db.AddTokensParams{UserID: userID, Day: date, Tokens: tokens})
}

func (q *quota) DeleteUser(ctx context.Context, userID string) error {
	return q.q.DeleteTokenUsage(ctx, userID)
}
