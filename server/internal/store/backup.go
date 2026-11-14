package store

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

type backups struct {
	q       *db.Queries
	pool    *pgxpool.Pool
	objects *os.Root
}

// Backups persists metadata in PostgreSQL and snapshot objects in the local
// directory. The production S3 adapter can replace this object backend.
func Backups(pool *pgxpool.Pool, objects *os.Root) backup.Store {
	return &backups{db.New(pool), pool, objects}
}

func (b *backups) Put(ctx context.Context, userID string, meta backup.Meta, data io.Reader, keep int) error {
	if err := b.saveObject(meta, data); err != nil {
		return err
	}
	removed, err := inTransaction(ctx, b.pool, func(q *db.Queries) ([]string, error) {
		if _, err := q.LockBackupAccount(ctx, userID); err != nil {
			return nil, err
		}
		if err := q.InsertBackup(ctx, db.InsertBackupParams{
			ID: meta.ID, UserID: userID, Sha256: meta.SHA256, Size: meta.Size,
			SchemaVersion: int32(meta.SchemaVersion), DeviceName: meta.DeviceName, CreatedAt: timestamp(meta.CreatedAt),
		}); err != nil {
			return nil, err
		}
		return q.PruneBackups(ctx, db.PruneBackupsParams{UserID: userID, Keep: int32(keep)})
	})
	if err != nil {
		// Resolve an uncertain commit before removing its object.
		rowCtx := context.WithoutCancel(ctx)
		if _, readErr := b.q.BackupByID(rowCtx, db.BackupByIDParams{UserID: userID, ID: meta.ID}); errors.Is(notFound(readErr, backup.ErrNotFound), backup.ErrNotFound) {
			_ = b.objects.Remove(meta.ID)
		}
		return err
	}
	return b.removeObjects(removed)
}

func (b *backups) saveObject(meta backup.Meta, data io.Reader) error {
	f, err := b.objects.OpenFile(meta.ID, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	written, writeErr := io.Copy(f, data)
	if writeErr == nil && written != meta.Size {
		writeErr = fmt.Errorf("backup object size mismatch")
	}
	if writeErr == nil {
		writeErr = f.Sync()
	}
	if err := errors.Join(writeErr, f.Close()); err != nil {
		_ = b.objects.Remove(meta.ID)
		return err
	}
	return nil
}

func (b *backups) List(ctx context.Context, userID string) ([]backup.Meta, error) {
	rows, err := b.q.Backups(ctx, userID)
	if err != nil {
		return nil, err
	}
	result := make([]backup.Meta, 0, len(rows))
	for _, row := range rows {
		result = append(result, backupMeta(row))
	}
	return result, nil
}

func (b *backups) Open(ctx context.Context, userID, id string) (backup.Meta, io.ReadCloser, error) {
	row, err := b.q.BackupByID(ctx, db.BackupByIDParams{UserID: userID, ID: id})
	if err != nil {
		return backup.Meta{}, nil, notFound(err, backup.ErrNotFound)
	}
	f, err := b.objects.Open(row.ID)
	if err != nil {
		return backup.Meta{}, nil, err
	}
	return backupMeta(row), f, nil
}

func (b *backups) Delete(ctx context.Context, userID, id string) error {
	count, err := b.q.DeleteBackup(ctx, db.DeleteBackupParams{UserID: userID, ID: id})
	if err != nil {
		return err
	}
	if count == 0 {
		return backup.ErrNotFound
	}
	return b.removeObjects([]string{id})
}

func (b *backups) DeleteUser(ctx context.Context, userID string) error {
	ids, err := b.q.DeleteUserBackups(ctx, userID)
	if err != nil {
		return err
	}
	return b.removeObjects(ids)
}

func (b *backups) removeObjects(ids []string) error {
	var failed error
	for _, id := range ids {
		if err := b.objects.Remove(id); err != nil && !errors.Is(err, os.ErrNotExist) {
			failed = errors.Join(failed, err)
		}
	}
	return failed
}

func backupMeta(row db.Backup) backup.Meta {
	return backup.Meta{
		ID: row.ID, SHA256: row.Sha256, Size: row.Size, SchemaVersion: int(row.SchemaVersion),
		DeviceName: row.DeviceName, CreatedAt: row.CreatedAt.Time,
	}
}
