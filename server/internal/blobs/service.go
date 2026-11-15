package blobs

import (
	"context"
	"errors"
	"io"
)

// ErrTooLarge reports an attachment above the configured size limit.
var ErrTooLarge = errors.New("blobs: attachment exceeds the size limit")

// Service owns the business rules of attachments: the size limit and account
// scoping. The handler deals with HTTP and hashing; the store keeps bytes.
type Service struct {
	store    Store
	maxBytes int64
}

func NewService(store Store, maxBytes int64) *Service {
	return &Service{store: store, maxBytes: maxBytes}
}

func (s *Service) MaxBytes() int64 { return s.maxBytes }

func (s *Service) Stat(ctx context.Context, userID, sha string) (int64, error) {
	return s.store.Stat(ctx, userID, sha)
}

func (s *Service) Open(ctx context.Context, userID, sha string) (io.ReadCloser, int64, error) {
	return s.store.Open(ctx, userID, sha)
}

// Put stores one attachment after the caller has verified the content hash.
func (s *Service) Put(ctx context.Context, userID, sha string, size int64, data io.Reader) error {
	if size > s.maxBytes {
		return ErrTooLarge
	}
	return s.store.Save(ctx, userID, sha, size, data)
}
