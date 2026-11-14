// Package pg 是 auth、syncsvc、backup 与 llmproxy 四个存储接口的 PostgreSQL 实现。
//
// 查询写进 internal/store/queries 下的 .sql 文件，由 sqlc 生成带类型的方法
// （ADR-0015 第一项）。表结构唯一真相是 internal/store/schema.sql；开发阶段不写
// 迁移，结构变化时按它重建（ADR-0001）。
package pg

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/store"
	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// Store 同时实现四个存储接口；账号删除靠外键级联清理其余表，所以
// DeleteUser 只有一份，语义是“删除这个账号”。
type Store struct {
	pool  *pgxpool.Pool
	q     *db.Queries
	blobs BlobStore
}

var (
	_ auth.Store           = (*Store)(nil)
	_ syncsvc.Store        = (*Store)(nil)
	_ backup.Store         = (*Store)(nil)
	_ interface{ Close() } = (*Store)(nil)
)

// Options 是打开连接时的可选项。
type Options struct {
	// BlobDir 存放整库备份的字节；对象存储就绪前用它落盘，保证进程重启不丢。
	BlobDir string
	// MaxConns 为空时用 pgxpool 的默认值。
	MaxConns int32
}

// Open 连接 PostgreSQL 并返回四个接口共用的实现。
func Open(ctx context.Context, dsn string, opts Options) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("pg: 解析连接串失败: %w", err)
	}
	if opts.MaxConns > 0 {
		cfg.MaxConns = opts.MaxConns
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("pg: 建立连接池失败: %w", err)
	}
	blobs, err := NewFilesystemBlobs(opts.BlobDir)
	if err != nil {
		pool.Close()
		return nil, err
	}
	return &Store{pool: pool, q: db.New(pool), blobs: blobs}, nil
}

// Ping 报告数据库是否可达，供 /readyz 使用。
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// Close 关闭连接池。
func (s *Store) Close() { s.pool.Close() }

// ApplySchema 在空库上按 schema.sql 建表；库已有表时保持原样。
func (s *Store) ApplySchema(ctx context.Context) error {
	_, err := s.pool.Exec(ctx, store.Schema)
	if err != nil {
		return fmt.Errorf("pg: 建表失败: %w", err)
	}
	return nil
}

// ---- auth.Store ----

func (s *Store) CreateUser(ctx context.Context, u auth.User) error {
	err := s.q.CreateUser(ctx, db.CreateUserParams{
		ID:           u.ID,
		Email:        u.Email,
		PasswordHash: u.PasswordHash,
	})
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return auth.ErrEmailTaken
	}
	return err
}

func (s *Store) UserByEmail(ctx context.Context, email string) (auth.User, error) {
	row, err := s.q.UserByEmail(ctx, email)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.User{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.User{}, err
	}
	return auth.User{
		ID:           row.ID,
		Email:        row.Email,
		PasswordHash: row.PasswordHash,
		CreatedAt:    row.CreatedAt.Time,
	}, nil
}

func (s *Store) UserByID(ctx context.Context, id string) (auth.User, error) {
	row, err := s.q.UserByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.User{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.User{}, err
	}
	return auth.User{
		ID:           row.ID,
		Email:        row.Email,
		PasswordHash: row.PasswordHash,
		CreatedAt:    row.CreatedAt.Time,
	}, nil
}

// DeleteUser 删除账号；会话、提交序列、备份与用量按外键级联删除，
// 备份字节由备份表被删之前先取出来清掉。
func (s *Store) DeleteUser(ctx context.Context, userID string) error {
	ids, err := s.q.ListBackups(ctx, userID)
	if err != nil {
		return err
	}
	tag, err := s.pool.Exec(ctx, "DELETE FROM app_user WHERE id = $1", userID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return auth.ErrNotFound
	}
	for _, b := range ids {
		if err := s.blobs.Remove(ctx, userID, b.ID); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) CreateSession(ctx context.Context, sess auth.Session) error {
	return s.q.CreateSession(ctx, db.CreateSessionParams{
		ID:             sess.ID,
		UserID:         sess.UserID,
		DeviceName:     sess.DeviceName,
		AccessHash:     sess.AccessHash,
		RefreshHash:    sess.RefreshHash,
		AccessExpires:  pgTime(sess.AccessExpires),
		RefreshExpires: pgTime(sess.RefreshExpires),
	})
}

func (s *Store) SessionByAccessHash(ctx context.Context, hash string) (auth.Session, error) {
	row, err := s.q.SessionByAccessHash(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Session{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Session{}, err
	}
	return auth.Session{
		ID:             row.ID,
		UserID:         row.UserID,
		DeviceName:     row.DeviceName,
		AccessHash:     row.AccessHash,
		RefreshHash:    row.RefreshHash,
		AccessExpires:  row.AccessExpires.Time,
		RefreshExpires: row.RefreshExpires.Time,
		CreatedAt:      row.CreatedAt.Time,
	}, nil
}

func (s *Store) SessionByRefreshHash(ctx context.Context, hash string) (auth.Session, error) {
	row, err := s.q.SessionByRefreshHash(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.Session{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.Session{}, err
	}
	return auth.Session{
		ID:             row.ID,
		UserID:         row.UserID,
		DeviceName:     row.DeviceName,
		AccessHash:     row.AccessHash,
		RefreshHash:    row.RefreshHash,
		AccessExpires:  row.AccessExpires.Time,
		RefreshExpires: row.RefreshExpires.Time,
		CreatedAt:      row.CreatedAt.Time,
	}, nil
}

func (s *Store) DeleteSession(ctx context.Context, id string) error {
	return s.q.DeleteSession(ctx, id)
}

func (s *Store) DeleteUserSessions(ctx context.Context, userID string) error {
	return s.q.DeleteUserSessions(ctx, userID)
}

func pgTime(t time.Time) pgtype.Timestamptz { return pgtype.Timestamptz{Time: t, Valid: !t.IsZero()} }
