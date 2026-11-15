package syncsvc

import (
	"context"
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
}

func NewService(store Store, schemaVersion int) *Service {
	return &Service{store: store, schemaVersion: schemaVersion}
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
	last := position
	if n := len(commits); n > 0 {
		if seq := commits[n-1].Seq; seq != nil {
			last = *seq
		}
	}
	return PullResult{Commits: commits, Head: head, HasMore: last < head}, nil
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
