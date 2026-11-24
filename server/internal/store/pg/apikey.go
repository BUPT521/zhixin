package pg

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// 模型代理的接入密钥（ADR-0063）。密钥只在签发那一次以明文出现，这里按摘要读写。

// CreateKey 在一个事务里核对有效密钥上限并写入。同一账号的签发在事务级 advisory
// lock 上排队：一条 INSERT … SELECT 自己看不到并发事务尚未提交的插入，两个请求
// 会同时按旧计数通过；锁放在计数之前，后来的请求读到的是前一个事务提交之后的
// 计数，上限因此守得住。
func (s *Store) CreateKey(ctx context.Context, key auth.APIKey, keyHash string, maxActive int) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("pg: 开始签发密钥事务失败: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "api_key:"+key.UserID); err != nil {
		return fmt.Errorf("pg: 锁定账号的密钥签发失败: %w", err)
	}
	rows, err := db.New(tx).CreateApiKey(ctx, db.CreateApiKeyParams{
		ID:        key.ID,
		UserID:    key.UserID,
		Name:      key.Name,
		Prefix:    key.Prefix,
		KeyHash:   keyHash,
		MaxActive: int64(maxActive),
	})
	if err != nil {
		return err
	}
	if rows == 0 {
		return auth.ErrKeyLimit
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("pg: 提交密钥签发失败: %w", err)
	}
	return nil
}

func (s *Store) KeysByUser(ctx context.Context, userID string) ([]auth.APIKey, error) {
	rows, err := s.q.ApiKeysByUser(ctx, userID)
	if err != nil {
		return nil, err
	}
	keys := make([]auth.APIKey, 0, len(rows))
	for _, row := range rows {
		keys = append(keys, auth.APIKey{
			ID:         row.ID,
			UserID:     row.UserID,
			Name:       row.Name,
			Prefix:     row.Prefix,
			Revoked:    row.RevokedAt.Valid,
			RevokedAt:  row.RevokedAt.Time,
			LastUsedAt: row.LastUsedAt.Time,
			CreatedAt:  row.CreatedAt.Time,
		})
	}
	return keys, nil
}

func (s *Store) KeyByHash(ctx context.Context, keyHash string) (auth.APIKey, error) {
	row, err := s.q.ApiKeyByHash(ctx, keyHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return auth.APIKey{}, auth.ErrNotFound
	}
	if err != nil {
		return auth.APIKey{}, err
	}
	return auth.APIKey{
		ID:              row.ID,
		UserID:          row.UserID,
		Name:            row.Name,
		Prefix:          row.Prefix,
		Revoked:         row.RevokedAt.Valid,
		RevokedAt:       row.RevokedAt.Time,
		LastUsedAt:      row.LastUsedAt.Time,
		CreatedAt:       row.CreatedAt.Time,
		ContactVerified: row.ContactVerified,
	}, nil
}

func (s *Store) RevokeKey(ctx context.Context, userID, id string) error {
	revoked, err := s.q.RevokeApiKey(ctx, db.RevokeApiKeyParams{ID: id, UserID: userID})
	if err == nil && revoked == 0 {
		return auth.ErrNotFound
	}
	return err
}

func (s *Store) RevokeAllKeys(ctx context.Context, userID string) (int64, error) {
	return s.q.RevokeApiKeysByUser(ctx, userID)
}

func (s *Store) TouchKey(ctx context.Context, id string) error {
	return s.q.TouchApiKey(ctx, id)
}

// PruneRevokedKeys 删除超过保留期的已撤销密钥行。已撤销的行只用于列表回看，
// 删除之后表与列表不会随反复签发与撤销无限变长。
func (s *Store) PruneRevokedKeys(ctx context.Context, revokedBefore time.Time) (int64, error) {
	return s.q.PruneRevokedApiKeys(ctx, pgtype.Timestamptz{Time: revokedBefore, Valid: true})
}
