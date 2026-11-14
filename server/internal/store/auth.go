package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

type accounts struct{ q *db.Queries }

func Accounts(pool *pgxpool.Pool) auth.Store { return &accounts{db.New(pool)} }

func timestamp(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

func (a *accounts) CreateUser(ctx context.Context, user auth.User) error {
	err := a.q.CreateUser(ctx, db.CreateUserParams{
		ID: user.ID, Email: user.Email, PasswordHash: user.PasswordHash, CreatedAt: timestamp(user.CreatedAt),
	})
	var conflict *pgconn.PgError
	if errors.As(err, &conflict) && conflict.Code == "23505" && conflict.ConstraintName == "app_user_email_key" {
		return auth.ErrEmailTaken
	}
	return err
}

func (a *accounts) UserByEmail(ctx context.Context, email string) (auth.User, error) {
	row, err := a.q.UserByEmail(ctx, email)
	return account(row), notFound(err, auth.ErrNotFound)
}

func (a *accounts) UserByID(ctx context.Context, id string) (auth.User, error) {
	row, err := a.q.UserByID(ctx, id)
	return account(row), notFound(err, auth.ErrNotFound)
}

func account(u db.AppUser) auth.User {
	return auth.User{ID: u.ID, Email: u.Email, PasswordHash: u.PasswordHash, CreatedAt: u.CreatedAt.Time}
}

func (a *accounts) DeleteUser(ctx context.Context, id string) error {
	count, err := a.q.DeleteAccount(ctx, id)
	if err == nil && count == 0 {
		return auth.ErrNotFound
	}
	return err
}

func (a *accounts) CreateSession(ctx context.Context, s auth.Session) error {
	return a.q.CreateSession(ctx, db.CreateSessionParams{
		ID: s.ID, UserID: s.UserID, DeviceName: s.DeviceName, AccessHash: s.AccessHash, RefreshHash: s.RefreshHash,
		AccessExpires: timestamp(s.AccessExpires), RefreshExpires: timestamp(s.RefreshExpires), CreatedAt: timestamp(s.CreatedAt),
	})
}

func (a *accounts) SessionByAccessHash(ctx context.Context, hash string) (auth.Session, error) {
	row, err := a.q.SessionByAccessHash(ctx, hash)
	return session(row), notFound(err, auth.ErrNotFound)
}

func (a *accounts) SessionByRefreshHash(ctx context.Context, hash string) (auth.Session, error) {
	row, err := a.q.SessionByRefreshHash(ctx, hash)
	return session(row), notFound(err, auth.ErrNotFound)
}

func session(s db.Session) auth.Session {
	return auth.Session{
		ID: s.ID, UserID: s.UserID, DeviceName: s.DeviceName, AccessHash: s.AccessHash, RefreshHash: s.RefreshHash,
		AccessExpires: s.AccessExpires.Time, RefreshExpires: s.RefreshExpires.Time, CreatedAt: s.CreatedAt.Time,
	}
}

func (a *accounts) DeleteSession(ctx context.Context, id string) error {
	count, err := a.q.DeleteSession(ctx, id)
	if err == nil && count == 0 {
		return auth.ErrNotFound
	}
	return err
}

func (a *accounts) DeleteUserSessions(ctx context.Context, id string) error {
	return a.q.DeleteUserSessions(ctx, id)
}
