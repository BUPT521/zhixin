package pg

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// 模型代理的接入密钥（ADR-0063）。密钥只在签发那一次以明文出现，这里按摘要读写。

func (s *Store) CreateKey(ctx context.Context, key auth.APIKey, keyHash string) error {
	return s.q.CreateApiKey(ctx, db.CreateApiKeyParams{
		ID:      key.ID,
		UserID:  key.UserID,
		Name:    key.Name,
		Prefix:  key.Prefix,
		KeyHash: keyHash,
	})
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
