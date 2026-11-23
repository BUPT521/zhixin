package syncsvc

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

const (
	maxPushCommits = 200
	defaultPull    = 200
	maxPull        = 1000

	// DefaultSnapshotGrace 是旧快照附件的回收宽限期：另一台设备可能刚从响应里
	// 读到旧哈希、正在下载，立即删除会让这次下载拿到 404（ADR-0047）。
	DefaultSnapshotGrace = 24 * time.Hour
	// DefaultDeviceActive 是压缩门槛看设备是否活跃的时间窗口（ADR-0047）。
	DefaultDeviceActive = 720 * time.Hour
	// capabilitySnapshot 是压缩门槛认的能力名，当前只有这一项（ADR-0048）。
	capabilitySnapshot = "snapshot"
	// deviceListLimit 是 GET /v1/sync/devices 一次返回的最大条数（ADR-0048）。
	deviceListLimit = 50
	// maxDeviceIDBytes 是设备标识与能力声明的长度上限，与契约一致（ADR-0048）。
	maxDeviceIDBytes = 64
	maxAliasRunes    = 64
)

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
	// compact 打开快照压缩。关闭时登记只写指针、预算压力也不删提交，仍超限就
	// 返回 ErrStorageFull（ADR-0047）。
	compact bool
	// snapshotGrace 是旧快照附件的回收宽限期。
	snapshotGrace time.Duration
	// deviceActive 是压缩门槛看设备是否活跃的时间窗口。
	deviceActive time.Duration
	// now 只用于给快照指针打登记时间与判断设备是否活跃，测试里可以替换。
	now func() time.Time
	// log 记录名册写入与旧快照回收的失败：这两件事失败都不影响同步响应。
	log *slog.Logger
}

func NewService(store Store, schemaVersion int) *Service {
	return &Service{
		store:         store,
		schemaVersion: schemaVersion,
		maxPullBytes:  DefaultPullBytes,
		snapshotBytes: DefaultSnapshotBytes,
		compactKeep:   DefaultCompactKeep,
		snapshotGrace: DefaultSnapshotGrace,
		deviceActive:  DefaultDeviceActive,
		now:           time.Now,
		log:           slog.Default(),
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

// SetCompact 打开或关闭快照压缩，装配时传 ZHIXIN_SYNC_COMPACT。关闭时登记快照
// 只写指针，推送遇到预算压力也不按快照压缩（ADR-0047）。
func (s *Service) SetCompact(on bool) *Service {
	s.compact = on
	return s
}

// SetSnapshotGrace 设置旧快照附件的回收宽限期，装配时传
// ZHIXIN_SYNC_SNAPSHOT_GRACE。非正值使用默认窗口。
func (s *Service) SetSnapshotGrace(d time.Duration) *Service {
	if d > 0 {
		s.snapshotGrace = d
	}
	return s
}

// SetDeviceActive 设置压缩门槛看设备是否活跃的时间窗口，装配时传
// ZHIXIN_SYNC_DEVICE_ACTIVE。非正值使用默认窗口。
func (s *Service) SetDeviceActive(d time.Duration) *Service {
	if d > 0 {
		s.deviceActive = d
	}
	return s
}

// SetLogger 注入记录名册与回收失败的日志，装配时传服务端日志。
func (s *Service) SetLogger(log *slog.Logger) *Service {
	if log != nil {
		s.log = log
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
	policy, err := s.compactPolicy(ctx, userID)
	if err != nil {
		return 0, err
	}
	return s.store.Append(ctx, userID, base, commits, policy)
}

// compactPolicy 决定这次登记或推送能不能删除快照覆盖的提交（ADR-0047）。
//
// 压缩开关关闭时不允许删除。打开之后还要看设备名册：账号最近
// ZHIXIN_SYNC_DEVICE_ACTIVE 内出现过的设备里，有任何一台没有声明 snapshot 能力
// 就不允许删除；名册里一台设备都没有时视为可以压缩。
func (s *Service) compactPolicy(ctx context.Context, userID string) (CompactPolicy, error) {
	policy := CompactPolicy{Keep: s.compactKeep}
	if !s.compact {
		return policy, nil
	}
	blocked, err := s.store.ActiveDeviceWithoutCapability(
		ctx, userID, s.now().Add(-s.deviceActive), capabilitySnapshot,
	)
	if err != nil {
		return policy, err
	}
	policy.AllowDelete = !blocked
	return policy, nil
}

// RegisterSnapshot 登记一份快照，按门槛压缩它覆盖的旧提交，并顺带回收过了
// 宽限期的旧快照附件（ADR-0043、ADR-0047）。
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
	if in.Seq < 1 || !httpx.ValidSHA256(in.Sha256) || !httpx.ValidSHA256(in.Digest) {
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
	policy, err := s.compactPolicy(ctx, userID)
	if err != nil {
		return State{}, err
	}
	state, err = s.store.RegisterSnapshot(ctx, userID, snap, policy)
	if err != nil {
		return state, err
	}
	// 登记成功之后顺带回收过了宽限期的旧快照附件。回收失败只写日志，不让登记
	// 失败，下一轮登记再试（ADR-0047）。
	s.reclaimOrphans(ctx, userID)
	return state, nil
}

// reclaimOrphans 回收本账号让位时间早于宽限期的旧快照附件。当前指针的哈希不
// 回收：SQL 已经排除，这里再排除一次。每一行独立回收，一行失败不影响其余行。
func (s *Service) reclaimOrphans(ctx context.Context, userID string) {
	state, err := s.store.State(ctx, userID)
	if err != nil {
		s.log.Warn("cannot read sync state before reclaiming snapshot attachments",
			slog.String("user_id", userID), slog.String("error", err.Error()))
		return
	}
	hashes, err := s.store.SnapshotOrphansBefore(ctx, userID, s.now().Add(-s.snapshotGrace))
	if err != nil {
		s.log.Warn("cannot list orphaned snapshot attachments",
			slog.String("user_id", userID), slog.String("error", err.Error()))
		return
	}
	for _, sha := range hashes {
		if state.Snapshot != nil && state.Snapshot.SHA256 == sha {
			continue
		}
		if err := s.store.ReclaimSnapshotOrphan(ctx, userID, sha); err != nil {
			s.log.Warn("cannot reclaim an orphaned snapshot attachment",
				slog.String("user_id", userID), slog.String("sha256", sha), slog.String("error", err.Error()))
		}
	}
}

// TouchDevice 记录一次带设备标识的同步请求：最近出现时间写服务端当前时间，能力
// 声明整组替换，别名不动（ADR-0048）。
func (s *Service) TouchDevice(ctx context.Context, userID, deviceID string, capabilities []string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" || len(deviceID) > maxDeviceIDBytes {
		return ErrInvalid
	}
	// 存储里始终是逗号分隔的小写能力名：去空白、转小写、按出现顺序去重。
	capabilities = SplitCapabilities(JoinCapabilities(capabilities))
	return s.store.TouchDevice(ctx, userID, deviceID, capabilities)
}

// EnsureDevice 在名册里补一行推送中出现的设备标识，能力与别名留空（ADR-0048）。
func (s *Service) EnsureDevice(ctx context.Context, userID, deviceID string) error {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" || len(deviceID) > maxDeviceIDBytes {
		return ErrInvalid
	}
	return s.store.EnsureDevice(ctx, userID, deviceID)
}

// Devices 返回账号名册，按最近出现时间倒序，最多 50 条（ADR-0048）。
func (s *Service) Devices(ctx context.Context, userID string) ([]Device, error) {
	return s.store.Devices(ctx, userID, deviceListLimit)
}

// RenameDevice 修改一台已有设备的别名。别名去掉首尾空白之后不超过 64 个字符，
// 空串表示清除；设备不在本账号名册里时返回 ErrDeviceNotFound（ADR-0048）。
func (s *Service) RenameDevice(ctx context.Context, userID, deviceID, alias string) (Device, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" || len(deviceID) > maxDeviceIDBytes {
		return Device{}, ErrInvalid
	}
	alias = strings.TrimSpace(alias)
	if utf8.RuneCountInString(alias) > maxAliasRunes {
		return Device{}, ErrInvalid
	}
	return s.store.RenameDevice(ctx, userID, deviceID, alias)
}

// Reset 清空账号的提交序列、快照指针、待回收行与设备名册，把 head 重置为 0。
// 设置页“清除云端数据”用它把服务端恢复到空白状态；账号与整库备份不受影响，规则
// 在这里而不是处理器里。
func (s *Service) Reset(ctx context.Context, userID string) error {
	return s.store.Reset(ctx, userID)
}
