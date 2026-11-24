package syncsvc

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// snapshotTestSchema 与本包用例使用的客户端 schema 保持一致；快照登记不比较
// schema，这里只为让推送通过校验。
const snapshotTestSchema = 29

// snapshotSHA 与 snapshotDigest 是合法的 64 位小写十六进制，形状与契约一致。
var (
	snapshotSHA    = strings.Repeat("a", 64)
	snapshotDigest = strings.Repeat("b", 64)
)

// fakeAttachments 模拟附件服务的归属查询：只有表里登记过的哈希算这个账号的
// 附件，其余按不存在处理。
type fakeAttachments map[string]int64

func (f fakeAttachments) Stat(_ context.Context, _ string, sha string) (int64, bool, error) {
	size, ok := f[sha]
	return size, ok, nil
}

// newSnapshotStore 返回一个可以拨动时钟的内存存储，压缩的保留期与预算路径因此
// 不需要真的等上几天。
func newSnapshotStore() (*MemoryStore, *time.Time) {
	clock := time.Now()
	store := NewMemoryStore()
	store.now = func() time.Time { return clock }
	return store, &clock
}

// TestRegisterSnapshotValidatesInput 守住登记的四条校验：形状、不能登记未来的
// 位置、附件必须属于这个账号、大小要落在合理区间。
func TestRegisterSnapshotValidatesInput(t *testing.T) {
	ctx := context.Background()
	store, _ := newSnapshotStore()
	atts := fakeAttachments{snapshotSHA: 4096}
	svc := NewService(store, snapshotTestSchema).SetAttachments(atts)

	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{
		Seq: 1, Sha256: snapshotSHA, Digest: snapshotDigest,
	}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("空序列上的快照应被拒绝，得到 %v", err)
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema), testCommit("r2", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}

	cases := []struct {
		name string
		in   api.SnapshotRegistration
	}{
		{"未来的位置", api.SnapshotRegistration{Seq: 3, Sha256: snapshotSHA, Digest: snapshotDigest}},
		{"序号为零", api.SnapshotRegistration{Seq: 0, Sha256: snapshotSHA, Digest: snapshotDigest}},
		{"哈希形状不对", api.SnapshotRegistration{Seq: 1, Sha256: "A" + snapshotSHA[1:], Digest: snapshotDigest}},
		{"摘要形状不对", api.SnapshotRegistration{Seq: 1, Sha256: snapshotSHA, Digest: strings.Repeat("c", 63)}},
		{"附件不属于这个账号", api.SnapshotRegistration{Seq: 1, Sha256: strings.Repeat("d", 64), Digest: snapshotDigest}},
	}
	for _, tc := range cases {
		if _, err := svc.RegisterSnapshot(ctx, "u1", tc.in); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%s 应返回 ErrInvalid，得到 %v", tc.name, err)
		}
	}

	// 附件大小超过单个快照上限时同样按无效登记处理。
	small := NewService(store, snapshotTestSchema).SetAttachments(atts).SetSnapshotBytes(1024)
	if _, err := small.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{
		Seq: 1, Sha256: snapshotSHA, Digest: snapshotDigest,
	}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("超出大小上限的快照应被拒绝，得到 %v", err)
	}

	// 没有装配附件查询时不静默接受。
	if _, err := NewService(store, snapshotTestSchema).RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{
		Seq: 1, Sha256: snapshotSHA, Digest: snapshotDigest,
	}); !errors.Is(err, ErrSnapshotUnsupported) {
		t.Fatalf("未装配附件查询时应返回 ErrSnapshotUnsupported，得到 %v", err)
	}
}

// TestRegisterSnapshotKeepsNewestOnly 守住“只保留最新一份”：位置更小的登记被
// 拒绝并带回当前位置，同一位置按幂等重试接受。
func TestRegisterSnapshotKeepsNewestOnly(t *testing.T) {
	ctx := context.Background()
	store, _ := newSnapshotStore()
	svc := NewService(store, snapshotTestSchema).SetAttachments(fakeAttachments{snapshotSHA: 4096, strings.Repeat("e", 64): 8192})
	if _, err := svc.Push(ctx, "u1", 0, []Commit{
		testCommit("r1", snapshotTestSchema),
		testCommit("r2", snapshotTestSchema),
		testCommit("r3", snapshotTestSchema),
	}); err != nil {
		t.Fatalf("push: %v", err)
	}

	state, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 3, Sha256: snapshotSHA, Digest: snapshotDigest})
	if err != nil || state.Snapshot == nil || state.Snapshot.Seq != 3 || state.EarliestSeq != 1 {
		t.Fatalf("登记最新位置: %+v, %v", state, err)
	}
	// 回退覆盖更新的快照被拒绝，返回的状态带着当前指针，处理器据此给出
	// extra.snapshot_seq。
	state, err = svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 2, Sha256: snapshotSHA, Digest: snapshotDigest})
	if !errors.Is(err, ErrSnapshotStale) {
		t.Fatalf("回退登记应返回 ErrSnapshotStale，得到 %v", err)
	}
	if state.Snapshot == nil || state.Snapshot.Seq != 3 {
		t.Fatalf("拒绝时也应返回当前指针: %+v", state)
	}
	// 同一位置的重试是幂等的，可以用新哈希刷新。
	other := strings.Repeat("e", 64)
	state, err = svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 3, Sha256: other, Digest: snapshotDigest})
	if err != nil || state.Snapshot == nil || state.Snapshot.SHA256 != other {
		t.Fatalf("同位置重试: %+v, %v", state, err)
	}
}

// TestPullRejectsCompactedRange 守住保留下界与 410 的判定：要的下一条已经删除
// 时返回 *CompactedError，恰好等于保留下界减一时仍按增量返回。
func TestPullRejectsCompactedRange(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	svc := NewService(store, snapshotTestSchema).
		SetAttachments(fakeAttachments{snapshotSHA: 4096}).
		SetCompact(true).
		SetCompactKeep(time.Hour)
	for i := range 4 {
		id := []string{"r1", "r2", "r3", "r4"}[i]
		if _, err := svc.Push(ctx, "u1", int64(i), []Commit{testCommit(id, snapshotTestSchema)}); err != nil {
			t.Fatalf("push %s: %v", id, err)
		}
	}

	// 保留期之内登记快照不删除任何提交，保留下界仍是 1。
	state, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 4, Sha256: snapshotSHA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 1 {
		t.Fatalf("保留期之内不应删除提交: %+v, %v", state, err)
	}

	// 拨快时钟到保留期之外，再登记一次，四条提交都早于保留窗口。
	*clock = clock.Add(2 * time.Hour)
	state, err = svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 4, Sha256: snapshotSHA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 5 || state.Head != 4 {
		t.Fatalf("压缩之后保留下界应为 5: %+v, %v", state, err)
	}

	after := int64(0)
	_, err = svc.Pull(ctx, "u1", &after, nil)
	var compacted *CompactedError
	if !errors.As(err, &compacted) || !errors.Is(err, ErrHistoryCompacted) {
		t.Fatalf("首次同步的位置也应被判定为越界，得到 %v", err)
	}
	if compacted.State.EarliestSeq != 5 || compacted.State.Snapshot == nil || compacted.State.Snapshot.Seq != 4 {
		t.Fatalf("越界错误应带回状态: %+v", compacted.State)
	}
	after = 2
	if _, err = svc.Pull(ctx, "u1", &after, nil); !errors.Is(err, ErrHistoryCompacted) {
		t.Fatalf("after=2 应越界，得到 %v", err)
	}
	after = 3
	if _, err = svc.Pull(ctx, "u1", &after, nil); !errors.Is(err, ErrHistoryCompacted) {
		t.Fatalf("after=3 的下一条已删除，应越界，得到 %v", err)
	}
	// 恰好等于保留下界减一时可以继续增量拉取。
	after = 4
	page, err := svc.Pull(ctx, "u1", &after, nil)
	if err != nil || len(page.Commits) != 0 || page.Head != 4 || page.EarliestSeq != 5 {
		t.Fatalf("after=4 = %+v, %v", page, err)
	}

	// 压缩之后的新提交照常拉取，保留下界不再变化。
	if r, err := svc.Push(ctx, "u1", 4, []Commit{testCommit("r5", snapshotTestSchema)}); err != nil || r.Head != 5 || r.Seqs[0] != 5 {
		t.Fatalf("压缩之后推送: %+v, %v", r, err)
	}
	page, err = svc.Pull(ctx, "u1", &after, nil)
	if err != nil || len(page.Commits) != 1 || page.Commits[0].Uid != "r5" || page.EarliestSeq != 5 {
		t.Fatalf("压缩之后的增量 = %+v, %v", page, err)
	}
}

// TestPushCompactsInsteadOfFailingAtBudget 守住预算路径：有快照时先压缩再判断，
// 没有快照时维持 ErrStorageFull。
func TestPushCompactsInsteadOfFailingAtBudget(t *testing.T) {
	ctx := context.Background()
	store, _ := newSnapshotStore()
	// 一条提交约几百字节，预算压到一条多一点，第二条推送必须先腾空间。
	store.SetMaxAccountBytes(600)
	svc := NewService(store, snapshotTestSchema).SetAttachments(fakeAttachments{snapshotSHA: 4096}).SetCompact(true)

	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("第一次推送: %v", err)
	}
	// 没有快照时压缩无从下手。
	if _, err := svc.Push(ctx, "u1", 1, []Commit{testCommit("r2", snapshotTestSchema)}); !errors.Is(err, ErrStorageFull) {
		t.Fatalf("没有快照时应返回 ErrStorageFull，得到 %v", err)
	}

	// 登记快照之后，预算不足会先删掉快照位置及之前的提交。
	store.mu.Lock()
	store.logs["u1"].snapshot = &Snapshot{Seq: 1, SHA256: snapshotSHA, Digest: snapshotDigest, CreatedAt: time.Now().UTC()}
	store.mu.Unlock()
	result, err := svc.Push(ctx, "u1", 1, []Commit{testCommit("r2", snapshotTestSchema)})
	if err != nil || result.Head != 2 {
		t.Fatalf("压缩之后应能继续推送: %+v, %v", result, err)
	}
	state, err := svc.State(ctx, "u1")
	if err != nil || state.EarliestSeq != 2 || state.Head != 2 {
		t.Fatalf("压缩之后的状态: %+v, %v", state, err)
	}
}

// TestSeenIDsSurviveCompaction 守住压缩之后的去重：已经接收过的提交身份仍然被
// 跳过，重放不会因为提交被删除而重新写入。
func TestSeenIDsSurviveCompaction(t *testing.T) {
	ctx := context.Background()
	store, _ := newSnapshotStore()
	svc := NewService(store, snapshotTestSchema)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema), testCommit("r2", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	// 直接压缩到 head，提交全部删除。
	store.mu.Lock()
	store.logs["u1"].compactThrough(2)
	store.mu.Unlock()

	state, err := svc.State(ctx, "u1")
	if err != nil || state.Head != 2 || state.EarliestSeq != 3 {
		t.Fatalf("压缩之后的状态: %+v, %v", state, err)
	}
	// 重放已经接收过的提交：按身份跳过，head 不变。
	if r, err := svc.Push(ctx, "u1", 2, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil || r.Head != 2 || r.Seqs[0] != 1 {
		t.Fatalf("重放应被跳过并回原序号: %+v, %v", r, err)
	}
	// 新的提交照常追加。
	if r, err := svc.Push(ctx, "u1", 2, []Commit{testCommit("r3", snapshotTestSchema)}); err != nil || r.Head != 3 {
		t.Fatalf("新提交: %+v, %v", r, err)
	}
	if page, err := svc.Pull(ctx, "u1", pointer(int64(2)), nil); err != nil || len(page.Commits) != 1 || *page.Commits[0].Seq != 3 {
		t.Fatalf("压缩之后的增量: %+v, %v", page, err)
	}
}

// TestResetClearsSnapshotAndSeen 守住清空云端数据的范围：快照指针、保留下界与
// 去重身份一起清掉，下一次同步从 0 开始。
func TestResetClearsSnapshotAndSeen(t *testing.T) {
	ctx := context.Background()
	store, _ := newSnapshotStore()
	svc := NewService(store, snapshotTestSchema).SetAttachments(fakeAttachments{snapshotSHA: 4096}).SetCompact(true)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: snapshotSHA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("register: %v", err)
	}
	store.mu.Lock()
	store.logs["u1"].compactThrough(1)
	store.mu.Unlock()

	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	state, err := svc.State(ctx, "u1")
	if err != nil || state.Head != 0 || state.EarliestSeq != 1 || state.Snapshot != nil {
		t.Fatalf("清空之后的状态: %+v, %v", state, err)
	}
	// 去重身份也清掉了：同一编号重新推送会被当成新提交。
	if r, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil || r.Head != 1 {
		t.Fatalf("清空之后重新推送: %+v, %v", r, err)
	}
}

// pointer 便于把字面量地址传进 Pull。
func pointer(v int64) *int64 { return &v }

// ---- 旧快照回收、压缩门槛与设备名册（ADR-0047、ADR-0048） ----

// newSnapshotService 返回与内存存储共用同一个可拨时钟的服务：宽限期、保留期与
// 设备活跃窗口都要在同一根时间轴上推进。
func newSnapshotService(store *MemoryStore, clock *time.Time) *Service {
	svc := NewService(store, snapshotTestSchema)
	svc.now = func() time.Time { return *clock }
	svc.SetLogger(slog.New(slog.NewTextHandler(io.Discard, nil)))
	return svc
}

// orphansBefore 列出 before 之前的待回收哈希。
func orphansBefore(t *testing.T, store *MemoryStore, userID string, before time.Time) []string {
	t.Helper()
	hashes, err := store.OrphanedAttachmentsBefore(context.Background(), userID, before)
	if err != nil {
		t.Fatalf("列出待回收: %v", err)
	}
	return hashes
}

// TestRegisterSnapshotRecordsOrphans 守住让位登记：新指针的哈希与旧指针不同时
// 旧哈希进入待回收表；同一哈希重复让位保留最早的时间；新指针重新使用一个待
// 回收的哈希时删掉那一行（ADR-0047 第 1 条）。
func TestRegisterSnapshotRecordsOrphans(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaA: 4096, shaB: 4096}).
		SetSnapshotGrace(time.Hour)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}

	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 A: %v", err)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 0 {
		t.Fatalf("第一次登记不该有待回收行: %v", got)
	}

	*clock = clock.Add(time.Minute)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 B: %v", err)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 1 || got[0] != shaA {
		t.Fatalf("登记 B 之后应只有 A 待回收: %v", got)
	}

	// 新指针重新使用 A：A 的待回收行删掉，B 成为待回收。
	*clock = clock.Add(time.Minute)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("重新登记 A: %v", err)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 1 || got[0] != shaB {
		t.Fatalf("重新登记 A 之后应只有 B 待回收: %v", got)
	}

	// 同一哈希重复让位时保留最早的 orphaned_at：先手动把 A 的让位时间拨早，再让
	// A 让位。B 的让位时间要晚于这里，回收时限才会先遇到 A。
	first := clock.Add(-30 * time.Minute)
	store.mu.Lock()
	store.logs["u1"].snapshot.SHA256 = shaA
	store.logs["u1"].orphans[shaA] = first
	store.mu.Unlock()
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("让位 A: %v", err)
	}
	store.mu.Lock()
	orphanedAt, ok := store.logs["u1"].orphans[shaA]
	store.mu.Unlock()
	if !ok || !orphanedAt.Equal(first) {
		t.Fatalf("重复让位应保留最早的让位时间: got %v want %v", orphanedAt, first)
	}
}

// TestReclaimSnapshotOrphansAfterGrace 守住宽限期与回收顺序：宽限期之内不回收，
// 过了宽限期先删字节与索引行（内存实现用回调模拟）、再删待回收行；任一步失败
// 时保留待回收行，下一轮登记再试（ADR-0047 第 2 条）。
func TestReclaimSnapshotOrphansAfterGrace(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	var reclaimed []string
	failing := false
	store.SetOrphanReclaimer(func(_, sha string) error {
		if failing {
			return errors.New("object storage is down")
		}
		reclaimed = append(reclaimed, sha)
		return nil
	})
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaA: 4096, shaB: 4096}).
		SetSnapshotGrace(time.Hour)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 A: %v", err)
	}
	*clock = clock.Add(30 * time.Minute)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 B: %v", err)
	}

	// 宽限期之内再登记一次：A 的字节还要留着，另一台设备可能正在下载。
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("宽限期内重试登记: %v", err)
	}
	if len(reclaimed) != 0 {
		t.Fatalf("宽限期内不应回收: %v", reclaimed)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 1 || got[0] != shaA {
		t.Fatalf("宽限期内 A 应仍然待回收: %v", got)
	}

	// 过了宽限期之后回收失败：待回收行保留。
	failing = true
	*clock = clock.Add(2 * time.Hour)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("回收失败时登记仍应成功: %v", err)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 1 || got[0] != shaA {
		t.Fatalf("回收失败应保留待回收行: %v", got)
	}

	// 下一轮登记重试，A 回收成功之后从待回收表消失。
	failing = false
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("重试登记: %v", err)
	}
	if len(reclaimed) != 1 || reclaimed[0] != shaA {
		t.Fatalf("过了宽限期应回收 A: %v", reclaimed)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 0 {
		t.Fatalf("回收之后不该再有待回收行: %v", got)
	}
}

// pointerLeakingStore 让待回收查询故意返回当前指针，验证服务层的第二道排除：
// 即使存储层漏掉了 SQL 的排除，当前指针的字节也不会被删（ADR-0047 第 3 条）。
type pointerLeakingStore struct{ *MemoryStore }

func (s pointerLeakingStore) OrphanedAttachmentsBefore(ctx context.Context, userID string, _ time.Time) ([]string, error) {
	state, err := s.MemoryStore.State(ctx, userID)
	if err != nil {
		return nil, err
	}
	if state.Snapshot != nil {
		return []string{state.Snapshot.SHA256}, nil
	}
	return nil, nil
}

// TestReclaimSkipsCurrentPointer 守住“当前指针的哈希不回收”：存储层把当前指针
// 混进待回收列表时，服务层也要跳过它。
func TestReclaimSkipsCurrentPointer(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	var reclaimed []string
	store.SetOrphanReclaimer(func(_, sha string) error {
		reclaimed = append(reclaimed, sha)
		return nil
	})
	leaky := pointerLeakingStore{MemoryStore: store}
	svc := NewService(leaky, snapshotTestSchema)
	svc.now = func() time.Time { return *clock }
	svc.SetLogger(slog.New(slog.NewTextHandler(io.Discard, nil)))
	svc.SetAttachments(fakeAttachments{shaA: 4096, shaB: 4096}).SetSnapshotGrace(time.Hour)

	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 A: %v", err)
	}
	*clock = clock.Add(2 * time.Hour)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 B: %v", err)
	}
	for _, sha := range reclaimed {
		if sha == shaB {
			t.Fatalf("当前指针的哈希不应被回收: %v", reclaimed)
		}
	}
}

// TestCompactionOffOnlyWritesPointer 守住压缩关闭时的两条路径：登记快照不删提交，
// 预算压力也不按快照压缩，仍然超限时返回 ErrStorageFull（ADR-0047 第 3 条）。
func TestCompactionOffOnlyWritesPointer(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaA: 4096}).
		SetCompactKeep(time.Hour).
		SetSnapshotGrace(time.Hour)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{
		testCommit("r1", snapshotTestSchema),
		testCommit("r2", snapshotTestSchema),
		testCommit("r3", snapshotTestSchema),
	}); err != nil {
		t.Fatalf("push: %v", err)
	}

	*clock = clock.Add(2 * time.Hour)
	state, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 3, Sha256: shaA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 1 || state.Head != 3 || state.Snapshot == nil {
		t.Fatalf("压缩关闭时登记只应写指针: %+v, %v", state, err)
	}

	store.SetMaxAccountBytes(600)
	if _, err := svc.Push(ctx, "u1", 3, []Commit{testCommit("r4", snapshotTestSchema)}); !errors.Is(err, ErrStorageFull) {
		t.Fatalf("压缩关闭时预算压力应返回 ErrStorageFull，得到 %v", err)
	}
}

// TestCompactionGateFollowsDeviceCapabilities 守住设备名册的压缩门槛：有活跃设备
// 没有声明 snapshot 能力时，登记与预算压力两条路径都不删提交；设备都声明之后
// 两条路径照常删（ADR-0047 第 3 条）。
func TestCompactionGateFollowsDeviceCapabilities(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaA: 4096}).
		SetCompact(true).
		SetCompactKeep(time.Hour).
		SetSnapshotGrace(time.Hour)

	if _, err := svc.Push(ctx, "u1", 0, []Commit{
		testCommit("r1", snapshotTestSchema),
		testCommit("r2", snapshotTestSchema),
	}); err != nil {
		t.Fatalf("push: %v", err)
	}
	// 一台旧设备没有声明 snapshot 能力：登记照常成功，但不删提交。
	if err := svc.TouchDevice(ctx, "u1", "device-legacy", false, 0); err != nil {
		t.Fatalf("记录设备: %v", err)
	}
	*clock = clock.Add(2 * time.Hour)
	state, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 2, Sha256: shaA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 1 || state.Head != 2 {
		t.Fatalf("有设备缺能力时登记不应删提交: %+v, %v", state, err)
	}

	// 预算压力路径也不删：预算压到一条多一点，后续推送只能返回 ErrStorageFull。
	store.SetMaxAccountBytes(600)
	if _, err := svc.Push(ctx, "u1", 2, []Commit{testCommit("r3", snapshotTestSchema)}); !errors.Is(err, ErrStorageFull) {
		t.Fatalf("有设备缺能力时预算压力应返回 ErrStorageFull，得到 %v", err)
	}

	// 设备声明能力之后，登记路径照常按保留期删除。
	if err := svc.TouchDevice(ctx, "u1", "device-legacy", true, 0); err != nil {
		t.Fatalf("更新设备能力: %v", err)
	}
	state, err = svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 2, Sha256: shaA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 3 || state.Head != 2 {
		t.Fatalf("设备都声明能力之后登记应删提交: %+v, %v", state, err)
	}

	// 预算压力路径同样照常删：另一个账号只用来单独观察压缩点。
	if _, err := svc.Push(ctx, "u2", 0, []Commit{testCommit("s1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push u2: %v", err)
	}
	if err := svc.TouchDevice(ctx, "u2", "device-a", true, 0); err != nil {
		t.Fatalf("记录 u2 设备: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u2", api.SnapshotRegistration{Seq: 1, Sha256: shaA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 u2: %v", err)
	}
	store.SetMaxAccountBytes(600)
	result, err := svc.Push(ctx, "u2", 1, []Commit{testCommit("s2", snapshotTestSchema)})
	if err != nil || result.Head != 2 {
		t.Fatalf("设备都声明能力之后预算压力应能继续推送: %+v, %v", result, err)
	}
	if state, err := svc.State(ctx, "u2"); err != nil || state.EarliestSeq != 2 {
		t.Fatalf("预算压力压缩之后保留下界应为 2: %+v, %v", state, err)
	}
}

// TestCompactionGateBlocksEmptyCapabilities 守住没有声明 snapshot 的设备：旧版本
// 客户端补行时留下的是 snapshot_capable = false，压缩门槛必须把它当成“不支持
// 快照”，登记与预算压力两条路径都不许删提交（ADR-0047、ADR-0054）。
func TestCompactionGateBlocksEmptyCapabilities(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaA: 4096}).
		SetCompact(true).
		SetCompactKeep(time.Hour).
		SetSnapshotGrace(time.Hour)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{
		testCommit("r1", snapshotTestSchema),
		testCommit("r2", snapshotTestSchema),
	}); err != nil {
		t.Fatalf("push: %v", err)
	}
	// 能力声明传空串：服务层归一化之后名册里就是空能力列表。
	if err := svc.TouchDevice(ctx, "u1", "device-empty", false, 0); err != nil {
		t.Fatalf("记录空能力设备: %v", err)
	}
	devices, err := svc.Devices(ctx, "u1")
	if err != nil || len(devices) != 1 || devices[0].SnapshotCapable {
		t.Fatalf("空能力设备应保存为不支持快照: %+v, %v", devices, err)
	}

	// 过了保留期登记：空能力设备挡住删除。
	*clock = clock.Add(2 * time.Hour)
	state, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 2, Sha256: shaA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 1 || state.Head != 2 {
		t.Fatalf("空能力设备应挡住登记路径的删除: %+v, %v", state, err)
	}

	// 预算压力路径同样不许删，仍然超限只返回 ErrStorageFull。
	store.SetMaxAccountBytes(600)
	if _, err := svc.Push(ctx, "u1", 2, []Commit{testCommit("r3", snapshotTestSchema)}); !errors.Is(err, ErrStorageFull) {
		t.Fatalf("空能力设备应挡住预算路径的删除，得到 %v", err)
	}
}

// TestResetClearsOrphansAndDevices 守住清空云端数据的范围：待回收行与设备名册
// 和提交序列、快照指针一起清掉（ADR-0047 第 4 条、ADR-0048 第 1 条）。
func TestResetClearsOrphansAndDevices(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaA := strings.Repeat("a", 64)
	shaB := strings.Repeat("b", 64)
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaA: 4096, shaB: 4096})
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaA, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 A: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaB, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记 B: %v", err)
	}
	if err := svc.TouchDevice(ctx, "u1", "device-a", true, 0); err != nil {
		t.Fatalf("记录设备: %v", err)
	}

	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(24*time.Hour)); len(got) != 0 {
		t.Fatalf("清空之后不该再有待回收行: %v", got)
	}
	if devices, err := svc.Devices(ctx, "u1"); err != nil || len(devices) != 0 {
		t.Fatalf("清空之后名册应为空: %+v, %v", devices, err)
	}
}
