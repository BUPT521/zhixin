// Package syncsvc keeps one linear commit log per account (ADR-0008 step 2).
//
// The server does not merge. A push must be based on the current server head;
// otherwise it is rejected with 409 and the client pulls, applies the remote
// commits locally as new local commits (so undo keeps working), and pushes
// again. Each commit carries the client's commit uid in request_id, so a
// retried push is a no-op; the field only identifies a commit and is never
// reused (ADR-0040). Field-level conflict handling stays on the client: the
// two-device protocol walkthrough of 2026-11-18 kept "last write wins,
// overwritten values stay in the history"
// (server/internal/server/sync_walkthrough_test.go).
//
// The log is compactable. An account whose device uploaded a checkpoint as an
// attachment may register it as the snapshot of sequence N, and commits that
// the snapshot already covers are deleted after the retention window
// (ADR-0043). A pull whose position falls behind the retained lower bound is
// answered with 410 history_compacted, and the client re-clones from the
// snapshot instead of replaying the log from sequence 1.
package syncsvc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// Change 与 Commit 直接使用契约生成的类型，服务端不再维护手写镜像。
//
// Change 的 before/after 在契约里声明为 json.RawMessage（x-go-type），行内容
// 原样转发：既不经 interface{} 解码，也不会把大整数变成 float64 而改变数值。
type (
	Change = api.Change
	Commit = api.Commit
)

var (
	// ErrHeadMoved means the push was not based on the current server head.
	ErrHeadMoved = errors.New("sync: server head moved")
	// ErrInvalid means a commit or a snapshot registration failed validation.
	ErrInvalid      = errors.New("sync: invalid commit")
	ErrPushTooLarge = errors.New("sync: push exceeds byte limit")
	ErrStorageFull  = errors.New("sync: account storage limit reached")
	ErrPullTooLarge = errors.New("sync: a stored commit exceeds the pull limit")
	// ErrSnapshotStale 表示登记的快照位置比已经保存的旧，不能回退覆盖
	// （ADR-0043）。
	ErrSnapshotStale = errors.New("sync: snapshot is older than the stored one")
	// ErrSnapshotUnsupported 表示装配没有注入附件查询，无法核对快照归属。
	ErrSnapshotUnsupported = errors.New("sync: snapshot attachments are not wired")
	// ErrHistoryCompacted 表示客户端的位置落在已经删除的区间，需要按快照重新克隆
	// （ADR-0043）。具体位置由 *CompactedError 带上。
	ErrHistoryCompacted = errors.New("sync: history was compacted")
	// ErrDeviceNotFound 表示要改名的设备不在这个账号的名册里（ADR-0048）。
	ErrDeviceNotFound = errors.New("sync: device is not in the roster")
)

const (
	MaxPushBytes     = 16 << 20
	MaxCommitBytes   = 2 << 20
	MaxAccountBytes  = 256 << 20
	DefaultPullBytes = 4 << 20
	// DefaultSnapshotBytes 是单个快照附件的默认上限，装配时用单个附件的上限覆盖：
	// 快照走附件接口上传，大小的第一层限制在那边（ADR-0043）。
	DefaultSnapshotBytes = 32 << 20
	// DefaultCompactKeep 是快照位置之下仍然保留提交的默认时间窗口，让落后不多的
	// 设备继续增量拉取，不必每次登记快照都重新克隆（ADR-0043）。
	DefaultCompactKeep = 7 * 24 * time.Hour
)

// Snapshot 是账号当前快照的指针：快照覆盖到的序列位置、附件哈希、客户端算出的
// 整库摘要与登记时间。服务端只保存与转发，不解析附件内容，也不校验摘要。
type Snapshot struct {
	Seq       int64
	SHA256    string
	Digest    string
	CreatedAt time.Time
}

// State 是一个账号的序列状态。
//
// EarliestSeq 是保留下界，即第一条仍然可以拉取的序号；没有删除过提交时为 1，
// 压缩之后等于已经删除到的位置加一。Head 是最后分配的序号，两者之差就是仍然
// 保留的提交条数。
type State struct {
	Head        int64
	EarliestSeq int64
	Snapshot    *Snapshot
}

// CompactPolicy 是压缩的保留口径（ADR-0043）与是否允许删除的开关（ADR-0047）。
type CompactPolicy struct {
	// Keep 是快照位置之下仍然要保留的提交时间窗口：服务端收到时间早于它减去
	// 当前时间的提交在登记快照时删除。预算不够时调用方忽略它，删掉快照位置之前
	// 的全部提交。
	Keep time.Duration
	// AllowDelete 表示这次操作允许删除快照覆盖的提交。压缩开关关闭，或名册里
	// 有活跃设备没有声明 snapshot 能力时为 false：登记只写指针，预算压力也不删
	// 提交，仍超限就返回 ErrStorageFull（ADR-0047）。
	AllowDelete bool
}

// Device 是账号名册里的一台设备（ADR-0048）。Capabilities 是解析之后的能力名，
// 存储里是逗号分隔的小写字符串。
type Device struct {
	DeviceID     string
	Alias        string
	Capabilities []string
	LastSeen     time.Time
}

// CompactedError 报告客户端的位置落在已经删除的区间，并带上删除之后的账号
// 状态，处理器把保留下界与快照指针写进 410 的 extra。
type CompactedError struct {
	State State
}

func (e *CompactedError) Error() string {
	return fmt.Sprintf("sync: position is behind the retained lower bound %d", e.State.EarliestSeq)
}

// Is 让 errors.Is(err, ErrHistoryCompacted) 成立。
func (e *CompactedError) Is(target error) bool { return target == ErrHistoryCompacted }

// Store is the per-account commit log and device roster.
type Store interface {
	// State returns the head, the retained lower bound and the snapshot pointer.
	State(ctx context.Context, userID string) (State, error)
	// Append atomically checks base == head and appends commits whose
	// request_id is new. When the account budget would be exceeded, the commits
	// the snapshot covers are deleted first if policy allows it. It returns the
	// resulting head, or ErrStorageFull.
	Append(ctx context.Context, userID string, base int64, commits []Commit, policy CompactPolicy) (int64, error)
	// After bounds the page before loading commit contents.
	After(ctx context.Context, userID string, after int64, limit int, maxBytes int64) ([]Commit, error)
	// RegisterSnapshot stores the newest snapshot pointer and, when policy
	// allows it, compacts commits the snapshot makes unnecessary. The old
	// pointer is recorded as an orphan. It returns ErrSnapshotStale when seq is
	// older than the stored pointer and ErrInvalid when seq is outside the log.
	RegisterSnapshot(ctx context.Context, userID string, snap Snapshot, policy CompactPolicy) (State, error)
	// Reset deletes every commit, the snapshot pointer, the orphan rows and the
	// device roster of the account and sets the head back to 0. An empty log is
	// not an error; a failure anywhere is returned.
	Reset(ctx context.Context, userID string) error
	// SnapshotOrphansBefore lists the hashes that gave way before the cutoff,
	// excluding the current snapshot pointer (ADR-0047).
	SnapshotOrphansBefore(ctx context.Context, userID string, before time.Time) ([]string, error)
	// ReclaimSnapshotOrphan removes the bytes of an old snapshot attachment
	// first, then its attachment index row and finally the orphan row. A
	// missing object counts as already deleted; a failure keeps the later rows
	// so that the next registration retries (ADR-0047).
	ReclaimSnapshotOrphan(ctx context.Context, userID, sha string) error
	// TouchDevice records a sync request that carried a device id: last_seen
	// becomes the server time and the capability list replaces the stored one
	// (ADR-0048).
	TouchDevice(ctx context.Context, userID, deviceID string, capabilities []string) error
	// EnsureDevice adds a device seen in a push without a device header. An
	// existing row keeps its alias and capabilities and only moves last_seen.
	EnsureDevice(ctx context.Context, userID, deviceID string) error
	// Devices lists the roster, newest first, at most limit rows.
	Devices(ctx context.Context, userID string, limit int) ([]Device, error)
	// RenameDevice changes the alias of a known device and returns the updated
	// row; an unknown device returns ErrDeviceNotFound.
	RenameDevice(ctx context.Context, userID, deviceID, alias string) (Device, error)
	// ActiveDeviceWithoutCapability reports whether any device seen since the
	// given time does not declare the capability. An empty roster is not a
	// blocker, so compaction stays allowed (ADR-0047).
	ActiveDeviceWithoutCapability(ctx context.Context, userID string, since time.Time, capability string) (bool, error)
}

// memoryLog 是一个账号在内存里的序列。
//
// commits 只保存仍然保留的提交，且序号连续：第一个元素的序号是 trimmedThrough
// 加一，所以 head 等于 trimmedThrough 加提交条数。seen 与 commits 分开保存，
// 压缩删掉旧提交之后，已经接收过的提交身份仍然按它去重（ADR-0043）。
type memoryLog struct {
	commits        []Commit
	sizes          []int64
	bytes          int64
	trimmedThrough int64
	seen           map[string]bool
	snapshot       *Snapshot
	// orphans 是让位的旧快照附件哈希与让位时间，devices 是设备名册
	// （ADR-0047、ADR-0048）。两者随 Reset 一起清掉。
	orphans map[string]time.Time
	devices map[string]*memoryDevice
}

// memoryDevice 是内存名册里的一台设备。
type memoryDevice struct {
	alias        string
	capabilities []string
	firstSeen    time.Time
	lastSeen     time.Time
}

// head 返回最后分配的序号。
func (l *memoryLog) head() int64 { return l.trimmedThrough + int64(len(l.commits)) }

// MemoryStore is a Store kept in process memory.
type MemoryStore struct {
	mu       sync.Mutex
	logs     map[string]*memoryLog
	maxBytes int64
	now      func() time.Time
	// orphanReclaimer 模拟对象字节与附件索引的删除，只给测试用：它返回错误时
	// 待回收行保留，与 PostgreSQL 实现的失败语义一致。
	orphanReclaimer func(userID, sha string) error
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{logs: map[string]*memoryLog{}, maxBytes: MaxAccountBytes, now: time.Now}
}

// SetOrphanReclaimer 给内存实现换一个回收动作，测试用它记录被回收的哈希并模拟
// 字节或索引删除失败；为空时回收只删待回收行。
func (m *MemoryStore) SetOrphanReclaimer(fn func(userID, sha string) error) *MemoryStore {
	m.orphanReclaimer = fn
	return m
}

// SetMaxAccountBytes 压低账号序列预算，只用于测试与本地联调：预算路径要在小
// 数据量下走通，不能真的写满 256 MiB。
func (m *MemoryStore) SetMaxAccountBytes(n int64) *MemoryStore {
	if n > 0 {
		m.maxBytes = n
	}
	return m
}

func (m *MemoryStore) ensure(userID string) *memoryLog {
	l := m.logs[userID]
	if l == nil {
		l = &memoryLog{seen: map[string]bool{}, orphans: map[string]time.Time{}, devices: map[string]*memoryDevice{}}
		m.logs[userID] = l
	}
	return l
}

func (m *MemoryStore) State(_ context.Context, userID string) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if l := m.logs[userID]; l != nil {
		return stateOf(l), nil
	}
	return State{EarliestSeq: 1}, nil
}

func stateOf(l *memoryLog) State {
	state := State{Head: l.head(), EarliestSeq: l.trimmedThrough + 1}
	if l.snapshot != nil {
		snap := *l.snapshot
		state.Snapshot = &snap
	}
	return state
}

// PlanAppend filters request IDs the account has already stored and checks that
// a non-empty batch is based on the current head. Both the in-memory and the
// PostgreSQL store call this, so the rules live in one place.
func PlanAppend(
	head, base int64,
	commits []Commit,
	seen map[string]bool,
) (fresh []Commit, newHead int64, err error) {
	for _, c := range commits {
		if seen[c.RequestId] {
			continue
		}
		seen[c.RequestId] = true
		fresh = append(fresh, c)
	}
	// A fully replayed push succeeds whatever its base: the client simply did
	// not see the previous response.
	if len(fresh) == 0 {
		return nil, head, nil
	}
	if base != head {
		return nil, head, ErrHeadMoved
	}
	return fresh, head + int64(len(fresh)), nil
}

func (m *MemoryStore) Append(_ context.Context, userID string, base int64, commits []Commit, policy CompactPolicy) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.ensure(userID)
	head := l.head()
	seen := make(map[string]bool, len(l.seen))
	for id := range l.seen {
		seen[id] = true
	}
	fresh, _, err := PlanAppend(head, base, commits, seen)
	if err != nil {
		return head, err
	}
	if len(fresh) == 0 {
		return head, nil
	}
	sizes := make([]int64, len(fresh))
	var added int64
	for i, c := range fresh {
		b, err := json.Marshal(c)
		if err != nil {
			return head, err
		}
		sizes[i] = int64(len(b)) + 256
		added += sizes[i]
	}
	if l.bytes+added > m.maxBytes {
		// 预算不够时先压缩：有快照且策略允许删除就删掉快照位置之前的全部提交，
		// 不按保留期过滤，再判断是否仍然超限（ADR-0043、ADR-0047）。
		if policy.AllowDelete && l.snapshot != nil {
			l.compactThrough(l.snapshot.Seq)
		}
		if l.bytes+added > m.maxBytes {
			return head, ErrStorageFull
		}
	}
	received := m.now()
	for i, c := range fresh {
		seq := l.head() + 1
		c.Seq = &seq
		c.ReceivedAt = &received
		l.commits = append(l.commits, c)
		l.sizes = append(l.sizes, sizes[i])
		l.bytes += sizes[i]
		l.seen[c.RequestId] = true
	}
	return l.head(), nil
}

func (m *MemoryStore) After(_ context.Context, userID string, after int64, limit int, maxBytes int64) ([]Commit, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.logs[userID]
	if l == nil {
		return nil, nil
	}
	if after < l.trimmedThrough {
		after = l.trimmedThrough
	}
	start := after - l.trimmedThrough
	if start >= int64(len(l.commits)) {
		return nil, nil
	}
	end := min(start+int64(limit), int64(len(l.commits)))
	return append([]Commit(nil), trimPullBytes(l.commits[start:end], maxBytes)...), nil
}

func (m *MemoryStore) RegisterSnapshot(_ context.Context, userID string, snap Snapshot, policy CompactPolicy) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.ensure(userID)
	head := l.head()
	if snap.Seq < 1 || snap.Seq > head {
		return stateOf(l), ErrInvalid
	}
	if l.snapshot != nil && snap.Seq < l.snapshot.Seq {
		return stateOf(l), ErrSnapshotStale
	}
	now := m.now()
	if snap.CreatedAt.IsZero() {
		snap.CreatedAt = now.UTC()
	}
	// 旧指针让位时记入待回收表：同一哈希重复让位保留最早的时间；新指针的哈希
	// 原本在待回收表里时删掉那一行，避免回收一份重新投入使用的附件（ADR-0047）。
	if old := l.snapshot; old != nil && old.SHA256 != "" && old.SHA256 != snap.SHA256 {
		if _, ok := l.orphans[old.SHA256]; !ok {
			l.orphans[old.SHA256] = now.UTC()
		}
	}
	delete(l.orphans, snap.SHA256)
	stored := snap
	l.snapshot = &stored
	// 常规压缩按保留期：快照位置及之前、早于保留窗口的提交删除，让落后不多的
	// 设备继续增量拉取（ADR-0043）。压缩开关关闭或有活跃设备没有声明能力时
	// 只写指针，不删提交（ADR-0047）。
	if policy.AllowDelete {
		l.compactOlder(snap.Seq, policy.Keep, now.Add(-policy.Keep))
	}
	return stateOf(l), nil
}

// SnapshotOrphansBefore 列出早于 before 让位的哈希，排除当前快照指针。
func (m *MemoryStore) SnapshotOrphansBefore(_ context.Context, userID string, before time.Time) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.logs[userID]
	if l == nil {
		return nil, nil
	}
	out := make([]string, 0, len(l.orphans))
	for sha, at := range l.orphans {
		if !at.Before(before) {
			continue
		}
		if l.snapshot != nil && l.snapshot.SHA256 == sha {
			continue
		}
		out = append(out, sha)
	}
	sort.Strings(out)
	return out, nil
}

// ReclaimSnapshotOrphan 先做模拟的字节与索引删除，成功之后再删待回收行；任何
// 一步失败都保留待回收行，与 PostgreSQL 实现一致。
func (m *MemoryStore) ReclaimSnapshotOrphan(_ context.Context, userID, sha string) error {
	if m.orphanReclaimer != nil {
		if err := m.orphanReclaimer(userID, sha); err != nil {
			return err
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if l := m.logs[userID]; l != nil {
		delete(l.orphans, sha)
	}
	return nil
}

// TouchDevice 更新名册：最近出现时间写服务端当前时间，能力整组替换，别名不动。
func (m *MemoryStore) TouchDevice(_ context.Context, userID, deviceID string, capabilities []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.ensure(userID)
	now := m.now().UTC()
	if d, ok := l.devices[deviceID]; ok {
		d.capabilities = append([]string(nil), capabilities...)
		d.lastSeen = now
		return nil
	}
	l.devices[deviceID] = &memoryDevice{
		capabilities: append([]string(nil), capabilities...),
		firstSeen:    now,
		lastSeen:     now,
	}
	return nil
}

// EnsureDevice 补一行设备；已有行只更新最近出现时间，能力与别名保持原样。
func (m *MemoryStore) EnsureDevice(_ context.Context, userID, deviceID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.ensure(userID)
	now := m.now().UTC()
	if d, ok := l.devices[deviceID]; ok {
		d.lastSeen = now
		return nil
	}
	l.devices[deviceID] = &memoryDevice{firstSeen: now, lastSeen: now}
	return nil
}

// Devices 按最近出现时间倒序列出名册，最多 limit 条。
func (m *MemoryStore) Devices(_ context.Context, userID string, limit int) ([]Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.logs[userID]
	if l == nil {
		return nil, nil
	}
	out := make([]Device, 0, len(l.devices))
	for id, d := range l.devices {
		out = append(out, Device{
			DeviceID:     id,
			Alias:        d.alias,
			Capabilities: append([]string{}, d.capabilities...),
			LastSeen:     d.lastSeen,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].LastSeen.Equal(out[j].LastSeen) {
			return out[i].LastSeen.After(out[j].LastSeen)
		}
		return out[i].DeviceID < out[j].DeviceID
	})
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// RenameDevice 改本账号已有设备的别名，未知设备返回 ErrDeviceNotFound。
func (m *MemoryStore) RenameDevice(_ context.Context, userID, deviceID, alias string) (Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.logs[userID]
	if l == nil {
		return Device{}, ErrDeviceNotFound
	}
	d, ok := l.devices[deviceID]
	if !ok {
		return Device{}, ErrDeviceNotFound
	}
	d.alias = alias
	return Device{
		DeviceID:     deviceID,
		Alias:        d.alias,
		Capabilities: append([]string{}, d.capabilities...),
		LastSeen:     d.lastSeen,
	}, nil
}

// ActiveDeviceWithoutCapability 报告最近 since 之后出现过的设备里有没有任何一台
// 没有声明 capability；名册为空时返回 false。
func (m *MemoryStore) ActiveDeviceWithoutCapability(_ context.Context, userID string, since time.Time, capability string) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l := m.logs[userID]
	if l == nil {
		return false, nil
	}
	for _, d := range l.devices {
		if d.lastSeen.Before(since) {
			continue
		}
		declared := false
		for _, name := range d.capabilities {
			if name == capability {
				declared = true
				break
			}
		}
		if !declared {
			return true, nil
		}
	}
	return false, nil
}

// SplitCapabilities 把逗号分隔的能力声明解析成小写名字：去首尾空白、丢掉空项、
// 按出现顺序去重（ADR-0048）。
func SplitCapabilities(raw string) []string {
	out := make([]string, 0, 4)
	seen := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		name := strings.ToLower(strings.TrimSpace(part))
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
	}
	return out
}

// JoinCapabilities 与 SplitCapabilities 相反，写入存储的逗号分隔形式。
func JoinCapabilities(names []string) string { return strings.Join(names, ",") }

// compactThrough 删除序号不大于 through 的提交前缀，用于预算压力下的压缩。
func (l *memoryLog) compactThrough(through int64) {
	l.dropPrefix(min(through-l.trimmedThrough, int64(len(l.commits))))
}

// compactOlder 删除序号不大于 through、且服务端收到时间早于 cutoff 的提交前缀。
func (l *memoryLog) compactOlder(through int64, keep time.Duration, cutoff time.Time) {
	if keep <= 0 {
		return
	}
	drop := int64(0)
	for i, c := range l.commits {
		if c.Seq == nil || *c.Seq > through || c.ReceivedAt == nil || !c.ReceivedAt.Before(cutoff) {
			break
		}
		drop = int64(i) + 1
	}
	l.dropPrefix(drop)
}

// dropPrefix 删掉前 n 条仍然保留的提交并推进保留下界。
func (l *memoryLog) dropPrefix(n int64) {
	if n <= 0 {
		return
	}
	n = min(n, int64(len(l.commits)))
	for _, size := range l.sizes[:n] {
		l.bytes -= size
	}
	l.commits = append([]Commit(nil), l.commits[n:]...)
	l.sizes = append([]int64(nil), l.sizes[n:]...)
	l.trimmedThrough += n
	if len(l.commits) == 0 {
		l.commits, l.sizes = nil, nil
	}
}

func (m *MemoryStore) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.logs, userID)
	return nil
}

// Reset 清空一个账号的提交序列、快照指针、待回收行与设备名册。内存实现里 head
// 由保留下界与提交条数算出，删掉日志即回到 0，空账号不算错误。
func (m *MemoryStore) Reset(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.logs, userID)
	return nil
}

// Validate checks the shape of a commit, not its business meaning: the server
// never interprets learning content. Op and Actor are checked through the
// generated enum validators, so the contract stays the only value list.
func Validate(c Commit, schemaVersion int) error {
	switch {
	case c.RequestId == "" || len(c.RequestId) > 64,
		c.DeviceId == "" || len(c.DeviceId) > 64,
		c.SchemaVersion != schemaVersion,
		!c.Actor.Valid(),
		c.Action == "",
		len(c.Changes) == 0:
		return ErrInvalid
	}
	for _, ch := range c.Changes {
		if ch.Table == "" || ch.RowKey == "" || !ch.Op.Valid() {
			return ErrInvalid
		}
		needBefore := ch.Op == api.Update || ch.Op == api.Delete
		needAfter := ch.Op == api.Insert || ch.Op == api.Update
		if (needBefore && ch.Before == nil) || (needAfter && ch.After == nil) {
			return ErrInvalid
		}
	}
	return nil
}
