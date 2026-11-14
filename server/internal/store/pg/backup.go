package pg

import (
	"context"
	"errors"
	"io"

	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// Put 先落字节再写元数据；写完按 keep 裁掉更旧的备份并删掉它们的字节。
//
// 顺序是有意的：元数据在字节之后写，进程在中间退出时只会留下没有元数据的孤儿
// 文件，不会出现“列表里有、下载失败”的记录。
func (s *Store) Put(ctx context.Context, userID string, m backup.Meta, data io.Reader, keep int) error {
	size, err := s.blobs.Put(ctx, userID, m.ID, data)
	if err != nil {
		return err
	}
	if err := s.q.InsertBackup(ctx, db.InsertBackupParams{
		ID:            m.ID,
		UserID:        userID,
		Sha256:        m.SHA256,
		Size:          size,
		SchemaVersion: int32(m.SchemaVersion),
		DeviceName:    m.DeviceName,
		CreatedAt:     pgTime(m.CreatedAt),
	}); err != nil {
		_ = s.blobs.Remove(ctx, userID, m.ID)
		return err
	}
	if keep <= 0 {
		return nil
	}
	stale, err := s.q.TrimBackups(ctx, db.TrimBackupsParams{
		UserID: userID,
		Offset: int32(keep),
	})
	if err != nil {
		return err
	}
	for _, id := range stale {
		if err := s.blobs.Remove(ctx, userID, id); err != nil {
			return err
		}
	}
	return nil
}

// List 按从新到旧返回元数据。
func (s *Store) List(ctx context.Context, userID string) ([]backup.Meta, error) {
	rows, err := s.q.ListBackups(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]backup.Meta, 0, len(rows))
	for _, row := range rows {
		out = append(out, backup.Meta{
			ID:            row.ID,
			SHA256:        row.Sha256,
			Size:          row.Size,
			SchemaVersion: int(row.SchemaVersion),
			DeviceName:    row.DeviceName,
			CreatedAt:     row.CreatedAt.Time,
		})
	}
	return out, nil
}

// Open 返回元数据与字节流。
func (s *Store) Open(ctx context.Context, userID, id string) (backup.Meta, io.ReadCloser, error) {
	row, err := s.q.BackupByID(ctx, db.BackupByIDParams{UserID: userID, ID: id})
	if errors.Is(err, pgx.ErrNoRows) {
		return backup.Meta{}, nil, backup.ErrNotFound
	}
	if err != nil {
		return backup.Meta{}, nil, err
	}
	rc, err := s.blobs.Open(ctx, userID, id)
	if err != nil {
		return backup.Meta{}, nil, err
	}
	return backup.Meta{
		ID:            row.ID,
		SHA256:        row.Sha256,
		Size:          row.Size,
		SchemaVersion: int(row.SchemaVersion),
		DeviceName:    row.DeviceName,
		CreatedAt:     row.CreatedAt.Time,
	}, rc, nil
}

// Delete 删掉一条备份的元数据与字节。
func (s *Store) Delete(ctx context.Context, userID, id string) error {
	if err := s.q.DeleteBackup(ctx, db.DeleteBackupParams{UserID: userID, ID: id}); err != nil {
		return err
	}
	return s.blobs.Remove(ctx, userID, id)
}

// Used 返回当天已用的 token 数；没有记录时是 0。
func (s *Store) Used(ctx context.Context, userID, day string) (int64, error) {
	used, err := s.q.UsedTokens(ctx, db.UsedTokensParams{
		UserID: userID,
		Day:    pgDate(day),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return used, err
}

// Add 累加当天用量。
func (s *Store) Add(ctx context.Context, userID, day string, tokens int64) error {
	return s.q.AddTokens(ctx, db.AddTokensParams{
		UserID: userID,
		Day:    pgDate(day),
		Tokens: tokens,
	})
}

// pgDate 把 YYYY-MM-DD 转成 PostgreSQL 的 date；解析失败时给一个不可能命中的零值，
// 调用方拿到的用量因此是 0，而不是记到别的日子上。
func pgDate(day string) pgtype.Date {
	parsed, err := time.Parse("2006-01-02", day)
	if err != nil {
		return pgtype.Date{}
	}
	return pgtype.Date{Time: parsed, Valid: true}
}
