package backup

import (
	"context"
	"errors"
	"io"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	// ErrSchemaVersion reports a snapshot produced by another client schema.
	ErrSchemaVersion = errors.New("backup: schema version does not match the server")
	// ErrTooLarge reports a snapshot above the configured size limit.
	ErrTooLarge = errors.New("backup: snapshot exceeds the size limit")
)

// Service owns the business rules of snapshots: which schema is accepted, how
// large one may be, how a device name is stored and how many are retained.
// The handler only deals with HTTP, and the store only keeps bytes and metadata.
type Service struct {
	store         Store
	maxBytes      int64
	keep          int
	schemaVersion int
	now           func() time.Time
}

func NewService(store Store, maxBytes int64, keep, schemaVersion int) *Service {
	return &Service{
		store:         store,
		maxBytes:      maxBytes,
		keep:          keep,
		schemaVersion: schemaVersion,
		now:           time.Now,
	}
}

func (s *Service) SchemaVersion() int { return s.schemaVersion }

func (s *Service) MaxBytes() int64 { return s.maxBytes }

// Upload validates one snapshot and stores it. The caller has already checked
// the body hash; size and schema are business rules checked here.
func (s *Service) Upload(
	ctx context.Context,
	userID, sha string,
	schema int,
	device string,
	size int64,
	data io.Reader,
) (Meta, error) {
	if schema != s.schemaVersion {
		return Meta{}, ErrSchemaVersion
	}
	if size > s.maxBytes {
		return Meta{}, ErrTooLarge
	}
	device = cleanDevice(device)
	meta := Meta{
		ID:            newID(),
		SHA256:        sha,
		Size:          size,
		SchemaVersion: schema,
		DeviceName:    device,
		CreatedAt:     s.now().UTC(),
	}
	if err := s.store.Put(ctx, userID, meta, data, s.keep); err != nil {
		return Meta{}, err
	}
	return meta, nil
}

func (s *Service) List(ctx context.Context, userID string) ([]Meta, error) {
	return s.store.List(ctx, userID)
}

func (s *Service) Open(ctx context.Context, userID, id string) (Meta, io.ReadCloser, error) {
	return s.store.Open(ctx, userID, id)
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	return s.store.Delete(ctx, userID, id)
}

// DeleteAll 清空账号在云端的全部备份。保留账号只清云端数据是设置页的独立动作，
// 规则留在这里而不是处理器里：账下没有备份时同样成功，存储失败原样上抛。
func (s *Service) DeleteAll(ctx context.Context, userID string) error {
	return s.store.DeleteAll(ctx, userID)
}

func cleanDevice(name string) string {
	name = strings.TrimSpace(name)
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) > 64 {
		return ""
	}
	return name
}
