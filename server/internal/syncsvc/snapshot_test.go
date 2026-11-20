package syncsvc

import (
	"context"
	"errors"
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
	if head, err := svc.Push(ctx, "u1", 4, []Commit{testCommit("r5", snapshotTestSchema)}); err != nil || head != 5 {
		t.Fatalf("压缩之后推送: %d, %v", head, err)
	}
	page, err = svc.Pull(ctx, "u1", &after, nil)
	if err != nil || len(page.Commits) != 1 || page.Commits[0].RequestId != "r5" || page.EarliestSeq != 5 {
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
	svc := NewService(store, snapshotTestSchema).SetAttachments(fakeAttachments{snapshotSHA: 4096})

	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("第一次推送: %v", err)
	}
	// 没有快照时压缩无从下手。
	if _, err := svc.Push(ctx, "u1", 1, []Commit{testCommit("r2", snapshotTestSchema)}); !errors.Is(err, ErrStorageFull) {
		t.Fatalf("没有快照时应返回 ErrStorageFull，得到 %v", err)
	}

	// 登记快照之后，预算不足会先删掉快照位置之前的提交。
	store.mu.Lock()
	store.logs["u1"].snapshot = &Snapshot{Seq: 1, SHA256: snapshotSHA, Digest: snapshotDigest, CreatedAt: time.Now().UTC()}
	store.mu.Unlock()
	head, err := svc.Push(ctx, "u1", 1, []Commit{testCommit("r2", snapshotTestSchema)})
	if err != nil || head != 2 {
		t.Fatalf("压缩之后应能继续推送: %d, %v", head, err)
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
	if head, err := svc.Push(ctx, "u1", 2, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil || head != 2 {
		t.Fatalf("重放应被跳过: %d, %v", head, err)
	}
	// 新的提交照常追加。
	if head, err := svc.Push(ctx, "u1", 2, []Commit{testCommit("r3", snapshotTestSchema)}); err != nil || head != 3 {
		t.Fatalf("新提交: %d, %v", head, err)
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
	svc := NewService(store, snapshotTestSchema).SetAttachments(fakeAttachments{snapshotSHA: 4096})
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
	if head, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil || head != 1 {
		t.Fatalf("清空之后重新推送: %d, %v", head, err)
	}
}

// pointer 便于把字面量地址传进 Pull。
func pointer(v int64) *int64 { return &v }
