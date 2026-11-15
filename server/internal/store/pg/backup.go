package pg

import (
	"context"
	"errors"
	"fmt"
	"io"

	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// Put 先落字节再写元数据；写完按 keep 裁掉更旧的备份并删掉它们的字节。
//
// 顺序是有意的：元数据在字节之后写，进程在中间退出时只会留下没有元数据的孤儿
// 对象，不会出现“列表里有、下载失败”的记录。
func (s *Store) Put(ctx context.Context, userID string, m backup.Meta, data io.Reader, keep int) error {
	// 时间在写字节之前校验：零值直接报错，不留没有元数据的孤儿对象。
	createdAt, err := pgTime(m.CreatedAt)
	if err != nil {
		return err
	}
	if err := s.objects.Put(ctx, objectstore.BackupKey(userID, m.ID), data, objectstore.Info{
		Size:        m.Size,
		ContentType: "application/zip",
	}); err != nil {
		return err
	}
	if err := s.q.InsertBackup(ctx, db.InsertBackupParams{
		ID:            m.ID,
		UserID:        userID,
		Sha256:        m.SHA256,
		Size:          m.Size,
		SchemaVersion: int32(m.SchemaVersion),
		DeviceName:    m.DeviceName,
		CreatedAt:     createdAt,
	}); err != nil {
		_ = s.objects.Remove(ctx, objectstore.BackupKey(userID, m.ID))
		return err
	}
	if keep <= 0 {
		return nil
	}
	stale, err := s.q.TrimBackups(ctx, db.TrimBackupsParams{
		UserID: userID,
		Keep:   int32(keep),
	})
	if err != nil {
		return err
	}
	for _, id := range stale {
		if err := s.objects.Remove(ctx, objectstore.BackupKey(userID, id)); err != nil {
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
	rc, _, err := s.objects.Open(ctx, objectstore.BackupKey(userID, id))
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
	return s.objects.Remove(ctx, objectstore.BackupKey(userID, id))
}

// Used 返回当天已用的 token 数；没有记录时是 0。
func (s *Store) Used(ctx context.Context, userID, day string) (int64, error) {
	date, err := pgDate(day)
	if err != nil {
		return 0, err
	}
	used, err := s.q.UsedTokens(ctx, db.UsedTokensParams{
		UserID: userID,
		Day:    date,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return used, err
}

// Add 累加当天用量。
func (s *Store) Add(ctx context.Context, userID, day string, tokens int64) error {
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	return s.q.AddTokens(ctx, db.AddTokensParams{
		UserID: userID,
		Day:    date,
		Tokens: tokens,
	})
}

// pgDate 把 YYYY-MM-DD 转成 PostgreSQL 的 date。格式不对时返回错误并由调用方
// 上抛：以前给零值会让用量悄悄记到“没有这一天”上，查出来的数看着像 0。
func pgDate(day string) (pgtype.Date, error) {
	parsed, err := time.Parse("2006-01-02", day)
	if err != nil {
		return pgtype.Date{}, fmt.Errorf("pg: 自然日 %q 不是 YYYY-MM-DD: %w", day, err)
	}
	return pgtype.Date{Time: parsed, Valid: true}, nil
}
