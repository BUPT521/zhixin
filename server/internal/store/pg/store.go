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
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/store"
	"github.com/BUPT521/zhixin/server/internal/store/db"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// Store 同时实现四个存储接口；账号删除靠外键级联清理其余表，所以
// DeleteUser 只有一份，语义是“删除这个账号”。
type Store struct {
	pool    *pgxpool.Pool
	q       *db.Queries
	objects objectstore.Store
}

var (
	_ auth.Store           = (*Store)(nil)
	_ syncsvc.Store        = (*Store)(nil)
	_ backup.Store         = (*Store)(nil)
	_ interface{ Close() } = (*Store)(nil)
)

// Options 是打开连接时的可选项。
type Options struct {
	// Objects 存放整库备份的字节；S3、本地目录与内存三种实现在 objectstore 里。
	Objects objectstore.Store
	// MaxConns 为空时用 pgxpool 的默认值。
	MaxConns int32
}

// Open 连接 PostgreSQL 并返回四个接口共用的实现。
func Open(ctx context.Context, dsn string, opts Options) (*Store, error) {
	if opts.Objects == nil {
		return nil, errors.New("pg: 需要 objectstore.Store 存放备份字节")
	}
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
	return &Store{pool: pool, q: db.New(pool), objects: opts.Objects}, nil
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

// DeleteUser 删除账号行；会话、提交序列、备份元数据与用量按外键级联删除。
// 对象存储里的字节由 DeleteUserObjects 清理，两步分开，账号删除因此可以重试。
func (s *Store) DeleteUser(ctx context.Context, userID string) error {
	_, err := s.q.DeleteUser(ctx, userID)
	return err
}

// DeleteUserObjects 删除账号名下的备份字节。附件字节由 blobs 包按自己的前缀
// 清理，两个前缀不同，服务装配时合成一次账号清理。
func (s *Store) DeleteUserObjects(ctx context.Context, userID string) error {
	return s.objects.RemovePrefix(ctx, objectstore.BackupPrefix(userID))
}

func (s *Store) CreateSession(ctx context.Context, sess auth.Session) error {
	accessExpires, err := pgTime(sess.AccessExpires)
	if err != nil {
		return err
	}
	refreshExpires, err := pgTime(sess.RefreshExpires)
	if err != nil {
		return err
	}
	return s.q.CreateSession(ctx, db.CreateSessionParams{
		ID:             sess.ID,
		UserID:         sess.UserID,
		DeviceName:     sess.DeviceName,
		AccessHash:     sess.AccessHash,
		RefreshHash:    sess.RefreshHash,
		AccessExpires:  accessExpires,
		RefreshExpires: refreshExpires,
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
	deleted, err := s.q.DeleteSession(ctx, id)
	if err == nil && deleted == 0 {
		return auth.ErrNotFound
	}
	return err
}

func (s *Store) DeleteUserSessions(ctx context.Context, userID string) error {
	return s.q.DeleteUserSessions(ctx, userID)
}

// pgTime 把时间转成 PostgreSQL 的 timestamptz。零值说明调用方漏了赋值，直接
// 报错，不再静默写成 NULL 或 0001-01-01 这类看不见的错误数据。
func pgTime(t time.Time) (pgtype.Timestamptz, error) {
	if t.IsZero() {
		return pgtype.Timestamptz{}, errors.New("pg: 时间字段为零值")
	}
	return pgtype.Timestamptz{Time: t, Valid: true}, nil
}
