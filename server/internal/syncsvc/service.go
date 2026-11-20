package syncsvc

import (
	"context"
	"encoding/json"
	"regexp"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
)

const (
	maxPushCommits = 200
	defaultPull    = 200
	maxPull        = 1000
)

// hashPattern 是快照附件哈希与整库摘要的形状：64 位小写十六进制，与附件的路径
// 参数一致（ADR-0043）。
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Attachments 报告一个账号名下是否存有某个附件，登记快照时用它核对归属与大小。
// 附件字节与索引由 blobs 包维护，这里只声明需要的一个查询，两个包因此不互相
// 引用存储。
type Attachments interface {
	// Stat 返回附件大小；found 为假表示这个账号没有这份内容。
	Stat(ctx context.Context, userID, sha string) (size int64, found bool, err error)
}

// PullResult is one page of remote commits plus the position it reached, the
// retained lower bound and the current snapshot pointer.
type PullResult struct {
	Commits     []Commit
	Head        int64
	HasMore     bool
	EarliestSeq int64
	Snapshot    *Snapshot
}

// Service owns the sync rules: which commits are accepted, how a push is
// validated, how a pull page is bounded and how a snapshot is registered. The
// handler only parses HTTP.
type Service struct {
	store         Store
	schemaVersion int
	// maxPullBytes 是一页提交内容的累计字节目标。
	maxPullBytes int64
	// attachments 用来核对快照附件的归属；装配没有注入时登记返回
	// ErrSnapshotUnsupported，不静默放过一个查不到归属的哈希。
	attachments Attachments
	// snapshotBytes 是单个快照附件的上限，装配时取单个附件的上限。
	snapshotBytes int64
	// compactKeep 是快照位置之下保留提交的时间窗口。
	compactKeep time.Duration
	// now 只用于给快照指针打登记时间，测试里可以替换。
	now func() time.Time
}

func NewService(store Store, schemaVersion int) *Service {
	return &Service{
		store:         store,
		schemaVersion: schemaVersion,
		maxPullBytes:  DefaultPullBytes,
		snapshotBytes: DefaultSnapshotBytes,
		compactKeep:   DefaultCompactKeep,
		now:           time.Now,
	}
}

// SetMaxPullBytes 设置一次拉取返回的提交内容累计字节上限，装配时传
// ZHIXIN_SYNC_PULL_MAX_BYTES。非正值使用默认上限。
func (s *Service) SetMaxPullBytes(n int64) *Service {
	if n > 0 {
		s.maxPullBytes = min(n, int64(MaxPushBytes))
	}
	return s
}

// SetAttachments 注入快照附件的归属查询，装配时传附件服务。
func (s *Service) SetAttachments(a Attachments) *Service {
	s.attachments = a
	return s
}

// SetSnapshotBytes 设置单个快照附件的上限，装配时传 ZHIXIN_MAX_ATTACHMENT_BYTES。
// 非正值使用默认上限。
func (s *Service) SetSnapshotBytes(n int64) *Service {
	if n > 0 {
		s.snapshotBytes = n
	}
	return s
}

// SetCompactKeep 设置快照位置之下保留提交的时间窗口，装配时传
// ZHIXIN_SYNC_COMPACT_KEEP。非正值使用默认窗口。
func (s *Service) SetCompactKeep(d time.Duration) *Service {
	if d > 0 {
		s.compactKeep = d
	}
	return s
}

func (s *Service) SchemaVersion() int { return s.schemaVersion }

// State 返回账号的序列状态：head、保留下界与当前快照指针。
func (s *Service) State(ctx context.Context, userID string) (State, error) {
	return s.store.State(ctx, userID)
}

// Pull returns commits with seq > after. Nil values select the defaults; an
// out-of-range explicit value is rejected. A position whose next commit has
// been compacted away is answered with *CompactedError so the handler can tell
// the client to re-clone from the snapshot (ADR-0043).
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
	state, err := s.store.State(ctx, userID)
	if err != nil {
		return PullResult{}, err
	}
	// 客户端要的下一条是 position+1；它已经删除时只能按快照重新克隆。position
	// 恰好等于保留下界减一时仍能继续，因为下一条就是保留下界。
	if position+1 < state.EarliestSeq {
		return PullResult{}, &CompactedError{State: state}
	}
	commits, err := s.store.After(ctx, userID, position, pageSize, s.maxPullBytes)
	if err != nil {
		return PullResult{}, err
	}
	if commits == nil {
		commits = []Commit{}
	}
	commits = trimPullBytes(commits, s.maxPullBytes)
	if len(commits) == 0 && position < state.Head {
		return PullResult{}, ErrPullTooLarge
	}
	last := position
	if n := len(commits); n > 0 {
		if seq := commits[n-1].Seq; seq != nil {
			last = *seq
		}
	}
	return PullResult{
		Commits:     commits,
		Head:        state.Head,
		HasMore:     last < state.Head,
		EarliestSeq: state.EarliestSeq,
		Snapshot:    state.Snapshot,
	}, nil
}

// trimPullBytes 按实际序列化后的累计字节数截断本页。
func trimPullBytes(commits []Commit, maxBytes int64) []Commit {
	var total int64
	for i := range commits {
		// 契约类型都能序列化，这里忽略编码错误；真出错时按整页返回，交给
		// 写响应的地方暴露，而不是悄悄少一条。
		b, err := json.Marshal(commits[i])
		if err == nil {
			total += int64(len(b))
		}
		if total > maxBytes {
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
	var total int64
	for i := range commits {
		// seq 由服务端分配（契约里是 readOnly），客户端带上来的值一律作废。
		commits[i].Seq = nil
		commits[i].ReceivedAt = nil
		if err := Validate(commits[i], s.schemaVersion); err != nil {
			return 0, err
		}
		b, err := json.Marshal(commits[i])
		if err != nil {
			return 0, ErrInvalid
		}
		total += int64(len(b))
		// PostgreSQL 的 JSONB 文本会为键值与数组元素补空格。为这部分及
		// 服务端生成的元数据留空间，保证新提交能够独立拉取。
		if len(b) > MaxCommitBytes || 2*int64(len(b))+256 > s.maxPullBytes || total > MaxPushBytes {
			return 0, ErrPushTooLarge
		}
	}
	return s.store.Append(ctx, userID, base, commits)
}

// RegisterSnapshot 登记一份快照并压缩它覆盖的旧提交（ADR-0043）。
//
// 返回的 State 在成功时是登记之后的状态；位置比已保存的旧时返回当前状态与
// ErrSnapshotStale，处理器用它的快照位置告诉客户端为什么被拒绝。
func (s *Service) RegisterSnapshot(
	ctx context.Context,
	userID string,
	in api.SnapshotRegistration,
) (State, error) {
	if s.attachments == nil {
		return State{}, ErrSnapshotUnsupported
	}
	if in.Seq < 1 || !hashPattern.MatchString(in.Sha256) || !hashPattern.MatchString(in.Digest) {
		return State{}, ErrInvalid
	}
	state, err := s.store.State(ctx, userID)
	if err != nil {
		return State{}, err
	}
	// 只能登记本账号已经到达的位置：未来的位置没有对应的提交，快照会指向一段
	// 服务端还没有的序列。
	if in.Seq > state.Head {
		return State{}, ErrInvalid
	}
	if state.Snapshot != nil && in.Seq < state.Snapshot.Seq {
		return state, ErrSnapshotStale
	}
	size, found, err := s.attachments.Stat(ctx, userID, in.Sha256)
	if err != nil {
		return State{}, err
	}
	// 附件必须属于这个账号；大小要落在合理区间，快照是整库投影的压缩结果，
	// 空文件与超过单个附件上限的值都按无效登记处理。
	if !found || size <= 0 || size > s.snapshotBytes {
		return State{}, ErrInvalid
	}
	snap := Snapshot{
		Seq:       in.Seq,
		SHA256:    in.Sha256,
		Digest:    in.Digest,
		CreatedAt: s.now().UTC(),
	}
	return s.store.RegisterSnapshot(ctx, userID, snap, CompactPolicy{Keep: s.compactKeep})
}

// Reset 清空账号的提交序列、快照指针与保留下界，把 head 重置为 0。设置页“清除
// 云端数据”用它把服务端恢复到空白状态；账号与整库备份不受影响，规则在这里而不是
// 处理器里。
func (s *Service) Reset(ctx context.Context, userID string) error {
	return s.store.Reset(ctx, userID)
}
