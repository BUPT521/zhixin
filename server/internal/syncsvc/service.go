package syncsvc

import (
	"context"
	"encoding/json"
)

const (
	maxPushCommits = 200
	defaultPull    = 200
	maxPull        = 1000
)

// PullResult is one page of remote commits plus the position it reached.
type PullResult struct {
	Commits []Commit
	Head    int64
	HasMore bool
}

// Service owns the sync rules: which commits are accepted, how a push is
// validated and how a pull page is bounded. The handler only parses HTTP.
type Service struct {
	store         Store
	schemaVersion int
	// maxPullBytes 是一页提交内容的累计字节上限；0 表示不设上限。
	maxPullBytes int64
}

func NewService(store Store, schemaVersion int) *Service {
	return &Service{store: store, schemaVersion: schemaVersion}
}

// SetMaxPullBytes 设置一次拉取返回的提交内容累计字节上限，装配时传
// ZHIXIN_SYNC_PULL_MAX_BYTES。超过时本页在这里截断并把 has_more 置真，客户端
// 接着拉下一页；没有它时一页最多 1000 条，单条的大小又没有上限，响应可能很大。
func (s *Service) SetMaxPullBytes(n int64) *Service {
	s.maxPullBytes = n
	return s
}

func (s *Service) SchemaVersion() int { return s.schemaVersion }

func (s *Service) Head(ctx context.Context, userID string) (int64, error) {
	return s.store.Head(ctx, userID)
}

// Pull returns commits with seq > after. Nil values select the defaults; an
// out-of-range explicit value is rejected.
func (s *Service) Pull(
	ctx context.Context,
	userID string,
	after *int64,
	limit *int,
) (PullResult, error) {
	position := int64(0)
	if after != nil {
		position = *after
	}
	if position < 0 {
		return PullResult{}, ErrInvalid
	}
	pageSize := defaultPull
	if limit != nil {
		pageSize = *limit
	}
	if pageSize < 1 || pageSize > maxPull {
		return PullResult{}, ErrInvalid
	}
	head, err := s.store.Head(ctx, userID)
	if err != nil {
		return PullResult{}, err
	}
	commits, err := s.store.After(ctx, userID, position, pageSize)
	if err != nil {
		return PullResult{}, err
	}
	if commits == nil {
		commits = []Commit{}
	}
	commits = s.trimPullBytes(commits)
	last := position
	if n := len(commits); n > 0 {
		if seq := commits[n-1].Seq; seq != nil {
			last = *seq
		}
	}
	return PullResult{Commits: commits, Head: head, HasMore: last < head}, nil
}

// trimPullBytes 按序列化后的字节数截断本页。单个提交本身就超过上限时仍然保留
// 它：否则客户端永远越不过这一条，会停在同一位置反复拉取同一页。响应里
// has_more 由截断后的末尾序号与 head 比较得出，截断天然表现为还有下一页。
func (s *Service) trimPullBytes(commits []Commit) []Commit {
	if s.maxPullBytes <= 0 {
		return commits
	}
	var total int64
	for i := range commits {
		// 契约类型都能序列化，这里忽略编码错误；真出错时按整页返回，交给
		// 写响应的地方暴露，而不是悄悄少一条。
		b, err := json.Marshal(commits[i])
		if err == nil {
			total += int64(len(b))
		}
		if total > s.maxPullBytes && i > 0 {
			return commits[:i]
		}
	}
	return commits
}

// Push validates one batch and appends it to the account log.
func (s *Service) Push(
	ctx context.Context,
	userID string,
	base int64,
	commits []Commit,
) (int64, error) {
	if len(commits) == 0 || len(commits) > maxPushCommits {
		return 0, ErrInvalid
	}
	for i := range commits {
		// seq 由服务端分配（契约里是 readOnly），客户端带上来的值一律作废。
		commits[i].Seq = nil
		if err := Validate(commits[i], s.schemaVersion); err != nil {
			return 0, err
		}
	}
	return s.store.Append(ctx, userID, base, commits)
}

// Reset 清空账号的提交序列并把 head 重置为 0。设置页“清除云端数据”用它把服务端
// 恢复到空白状态；账号与整库备份不受影响，规则在这里而不是处理器里。
func (s *Service) Reset(ctx context.Context, userID string) error {
	return s.store.Reset(ctx, userID)
}
