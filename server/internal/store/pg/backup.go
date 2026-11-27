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
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/store/db"
)

// Put 先落字节再写元数据；写完按 keep 裁掉更旧的备份并删掉它们的字节。
//
// 顺序是有意的：元数据在字节之后写，进程在中间退出时只会留下没有元数据的孤儿
// 对象，不会出现“列表里有、下载失败”的记录。
func (s *Store) Put(ctx context.Context, userID string, m backup.Meta, data io.Reader, keep int) error {
	if keep < 1 {
		return backup.ErrKeep
	}
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

// ListAllKeys 返回全部备份元数据对应的对象键，供后台对账比对 backups/ 下的
// 对象：库里查不到的键就是遗留字节，见 ADR-0037。
func (s *Store) ListAllKeys(ctx context.Context) ([]string, error) {
	rows, err := s.q.ListAllBackups(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(rows))
	for _, row := range rows {
		out = append(out, objectstore.BackupKey(row.UserID, row.ID))
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

// Delete 删掉当前账号的一份备份：先按 (user_id, id) 删元数据，删到一行才删除
// 对象键。
//
// 顺序有意与 Put 相反：先确认这行属于该账号，再去碰对象存储。0 行直接返回
// ErrNotFound，不按 id 拼键删字节——客户端猜出来的 id（哪怕形状像
// ../u2/<id>）也就没有机会删到别的账号。删元数据成功而删字节失败时，这次的
// 调用返回错误，遗留的对象由 DeleteAll 的前缀清理兜住。
func (s *Store) Delete(ctx context.Context, userID, id string) error {
	deleted, err := s.q.DeleteBackup(ctx, db.DeleteBackupParams{UserID: userID, ID: id})
	if err != nil {
		return err
	}
	if deleted == 0 {
		return backup.ErrNotFound
	}
	return s.objects.Remove(ctx, objectstore.BackupKey(userID, id))
}

// DeleteAll 清空一个账号的全部备份：先按账号列出备份、逐个删除对象键，再删
// 数据库行，最后按 backups/<账号>/ 前缀再清一次遗留对象。
//
// 前两步沿用 Delete 的键规则（键由 userID 与备份 id 拼出），第三步的前缀同样
// 带上账号，所以只清这个账号的目录，别的账号不受影响。最后一步兜住“元数据已
// 删、字节还在”的孤儿对象：Delete 删完元数据之后删字节失败、或 Put 写完字节
// 还没写元数据就退出，重试 DeleteAll 时会在这里收敛。
func (s *Store) DeleteAll(ctx context.Context, userID string) error {
	rows, err := s.q.ListBackups(ctx, userID)
	if err != nil {
		return err
	}
	for _, row := range rows {
		if err := s.objects.Remove(ctx, objectstore.BackupKey(userID, row.ID)); err != nil {
			return err
		}
	}
	if err := s.q.DeleteBackups(ctx, userID); err != nil {
		return err
	}
	return s.objects.RemovePrefix(ctx, objectstore.BackupPrefix(userID))
}

// Used 返回当天已经结算的计费 token 数。用途为空时返回两类合计。
func (s *Store) Used(ctx context.Context, userID, day string, kind llmproxy.Kind) (int64, error) {
	date, err := pgDate(day)
	if err != nil {
		return 0, err
	}
	return settledTokens(ctx, s.q, userID, date, kind)
}

// Add 累加当天某类模型的已结算用量，不归到具体密钥。
func (s *Store) Add(ctx context.Context, userID, day string, kind llmproxy.Kind, tokens int64) error {
	date, err := pgDate(day)
	if err != nil {
		return err
	}
	return s.q.SettleTokens(ctx, db.SettleTokensParams{
		UserID:             userID,
		Day:                date,
		Kind:               string(kind),
		ApiKeyID:           "",
		Actual:             tokens,
		RawEmbeddingTokens: tokens,
	})
}

// DailyLimit 返回账号单独调整过的每日共享额度，未设置时由调用方使用默认值。
func (s *Store) DailyLimit(ctx context.Context, userID string) (int64, bool, error) {
	return quotaOverride(ctx, s.q, userID)
}

func quotaOverride(ctx context.Context, q *db.Queries, userID string) (int64, bool, error) {
	limit, err := q.LLMQuotaOverride(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return limit.Int64, limit.Valid, nil
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
