// Package store adapts the generated PostgreSQL queries to business stores.
package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/store/db"
)

func inTransaction[T any](ctx context.Context, pool *pgxpool.Pool, run func(*db.Queries) (T, error)) (T, error) {
	var zero T
	tx, err := pool.Begin(ctx)
	if err != nil {
		return zero, err
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	value, err := run(db.New(tx))
	if err != nil {
		return value, err
	}
	return value, tx.Commit(ctx)
}

func notFound(err, target error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return target
	}
	return err
}
