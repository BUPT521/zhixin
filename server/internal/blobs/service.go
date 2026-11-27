package blobs

import (
	"context"
	"errors"
	"fmt"
	"io"
)

// Service owns the attachment rules that are not HTTP-level: the per-account
// total limit and account scoping. The handler deals with HTTP, the content hash
// and the single-object size limit (checked while spooling); the store keeps
// bytes and the quota index.
type Service struct {
	store        Store
	maxBytes     int64
	accountBytes int64
}

// NewService 组装附件服务。maxBytes 管单个附件；账号总量上限用
// SetAccountBytes 设置，对应 ZHIXIN_MAX_ACCOUNT_ATTACHMENT_BYTES。
func NewService(store Store, maxBytes int64) *Service {
	return &Service{store: store, maxBytes: maxBytes}
}

// SetAccountBytes 设置一个账号全部附件的总量上限；limit 小于等于 0 表示不设
// 上限。单独一个 setter 而不是构造参数，是为了让装配顺序不影响已有调用方：
// server.New 必须调用它，否则账号总量不受限制。
func (s *Service) SetAccountBytes(limit int64) *Service {
	s.accountBytes = limit
	return s
}

func (s *Service) MaxBytes() int64 { return s.maxBytes }

func (s *Service) Stat(ctx context.Context, userID, sha string) (int64, error) {
	return s.store.Stat(ctx, userID, sha)
}

func (s *Service) Open(ctx context.Context, userID, sha string) (io.ReadCloser, int64, error) {
	return s.store.Open(ctx, userID, sha)
}

// Put stores one attachment after the caller has verified the content hash and
// the single-object size limit (SpoolVerified enforces it before the body is
// handed over).
//
// 顺序是先预留配额再写字节：并发上传按预留后的总量判断，后到的一个拿到
// 413 storage_full，而不是两个都按旧的已用量通过检查、一起把账号写超。保存
// 失败时回滚预留，配额与索引不会留下一次没写成功的上传。
func (s *Service) Put(ctx context.Context, userID, sha string, size int64, data io.Reader) error {
	if _, err := s.store.Reserve(ctx, userID, sha, size, s.accountBytes); err != nil {
		return err
	}
	if err := s.store.Save(ctx, userID, sha, size, data); err != nil {
		if releaseErr := s.store.Release(ctx, userID, sha, size); releaseErr != nil {
			// 回滚也失败时把两个错误一起上报：调用方看到 500，日志里能看出
			// 配额可能多算了一点，由下一次上传或清理收敛。
			return errors.Join(err, fmt.Errorf("blobs: 回滚附件配额失败: %w", releaseErr))
		}
		return err
	}
	return nil
}
