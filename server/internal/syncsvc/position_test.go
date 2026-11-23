package syncsvc

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
)

// TestCompactionStopsAtActiveDevicePosition 守住常规压缩的设备位置门槛：快照位置
// 与保留期都允许删除时，常规压缩也不能越过活跃窗口内设备的最小位置；预算压力下
// 的压缩不看这个门槛（ADR-0054 第 3 条）。
func TestCompactionStopsAtActiveDevicePosition(t *testing.T) {
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
		testCommit("r3", snapshotTestSchema),
		testCommit("r4", snapshotTestSchema),
	}); err != nil {
		t.Fatalf("push: %v", err)
	}
	// 一台设备只应用了前两条，且仍在活跃窗口之内。
	if err := svc.TouchDevice(ctx, "u1", "device-behind", true, 2); err != nil {
		t.Fatalf("记录设备: %v", err)
	}
	devices, err := svc.Devices(ctx, "u1")
	if err != nil || len(devices) != 1 || devices[0].SyncedSeq != 2 {
		t.Fatalf("设备位置: %+v, %v", devices, err)
	}

	// 过了保留期再登记快照：常规压缩只能删到设备位置 2。
	*clock = clock.Add(2 * time.Hour)
	state, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 4, Sha256: shaA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 3 || state.Head != 4 {
		t.Fatalf("常规压缩应停在设备位置之后: %+v, %v", state, err)
	}
	// 落后的设备仍能增量拉取到剩下的提交。
	page, err := svc.Pull(ctx, "u1", pointer(2), nil)
	if err != nil || len(page.Commits) != 2 || page.EarliestSeq != 3 {
		t.Fatalf("落后设备应能增量拉取: %+v, %v", page, err)
	}

	// 预算压力下的压缩不看设备位置：预算压到只放得下快照位置之后的提交。
	store.SetMaxAccountBytes(1000)
	if r, err := svc.Push(ctx, "u1", 4, []Commit{testCommit("r5", snapshotTestSchema)}); err != nil || r.Head != 5 {
		t.Fatalf("预算压力下应能继续推送: %+v, %v", r, err)
	}
	state, err = svc.State(ctx, "u1")
	if err != nil || state.Head != 5 || state.EarliestSeq > 5 {
		t.Fatalf("预算压缩应越过设备位置: %+v, %v", state, err)
	}

	// 设备离开活跃窗口之后，常规压缩不再受它约束。
	*clock = clock.Add(DefaultDeviceActive + time.Hour)
	state, err = svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 5, Sha256: shaA, Digest: snapshotDigest})
	if err != nil || state.EarliestSeq != 6 || state.Head != 5 {
		t.Fatalf("没有活跃设备时常规压缩应删到快照位置: %+v, %v", state, err)
	}
}

// TestOrphanedAttachmentStaysInAccountQuota 守住配额口径：让位的旧快照附件在回收
// 之前仍然计入账号的附件总量，回收之后才从索引里消失（ADR-0047、审查 V2）。
func TestOrphanedAttachmentStaysInAccountQuota(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	shaOld := strings.Repeat("a", 64)
	shaNew := strings.Repeat("b", 64)
	var reclaimed []string
	store.SetOrphanReclaimer(func(_ string, sha string) error {
		reclaimed = append(reclaimed, sha)
		return nil
	})
	svc := newSnapshotService(store, clock).
		SetAttachments(fakeAttachments{shaOld: 4096, shaNew: 4096}).
		SetSnapshotGrace(time.Hour)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaOld, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记旧快照: %v", err)
	}
	*clock = clock.Add(time.Minute)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaNew, Digest: snapshotDigest}); err != nil {
		t.Fatalf("登记新快照: %v", err)
	}
	// 宽限期之内：旧附件让位但还在，回收列表里能看到它，也还没有被回收。
	if len(reclaimed) != 0 {
		t.Fatalf("宽限期内不应回收: %v", reclaimed)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 1 || got[0] != shaOld {
		t.Fatalf("让位的旧附件应在回收列表里: %v", got)
	}
	// 过了宽限期：登记时顺带回收，回收列表清空。
	*clock = clock.Add(2 * time.Hour)
	if _, err := svc.RegisterSnapshot(ctx, "u1", api.SnapshotRegistration{Seq: 1, Sha256: shaNew, Digest: snapshotDigest}); err != nil {
		t.Fatalf("再次登记: %v", err)
	}
	if len(reclaimed) != 1 || reclaimed[0] != shaOld {
		t.Fatalf("过了宽限期应回收旧附件: %v", reclaimed)
	}
	if got := orphansBefore(t, store, "u1", clock.Add(time.Hour)); len(got) != 0 {
		t.Fatalf("回收之后不该再有待回收附件: %v", got)
	}
}

// TestAdvanceDeviceNeverPassesHead 守住设备位置的上限：清除云端数据之后别的设备
// 还会带着旧的大位置来推送，位置不能被推到当前的 head 之外（ADR-0054）。
func TestAdvanceDeviceNeverPassesHead(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	svc := newSnapshotService(store, clock)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", snapshotTestSchema), testCommit("r2", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if err := svc.TouchDevice(ctx, "u1", "device-a", true, 100); err != nil {
		t.Fatalf("记录设备: %v", err)
	}
	devices, err := svc.Devices(ctx, "u1")
	if err != nil || len(devices) != 1 || devices[0].SyncedSeq != 2 {
		t.Fatalf("位置不应超过 head: %+v, %v", devices, err)
	}
	// 整批重放只按 base 取较大值，不推到当前 head。
	if err := svc.AdvanceDevice(ctx, "u1", "device-a", 1, false); err != nil {
		t.Fatalf("推进位置: %v", err)
	}
	if devices, err = svc.Devices(ctx, "u1"); err != nil || devices[0].SyncedSeq != 2 {
		t.Fatalf("整批重放不应改变位置: %+v, %v", devices, err)
	}
	// 清空之后 head 回到 0，旧的大位置同样减到 0。
	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("s1", snapshotTestSchema)}); err != nil {
		t.Fatalf("push: %v", err)
	}
	if err := svc.TouchDevice(ctx, "u1", "device-old", true, 500); err != nil {
		t.Fatalf("记录旧位置设备: %v", err)
	}
	devices, err = svc.Devices(ctx, "u1")
	if err != nil || len(devices) != 1 || devices[0].SyncedSeq != 1 {
		t.Fatalf("旧的大位置不应超过当前 head: %+v, %v", devices, err)
	}
}

// TestPutRefStoresTombstoneWithoutReviving 守住命名版本的写入规则：后写覆盖先写、
// 删除留墓碑、比删除时间更早的写入不复活（ADR-0054）。
func TestPutRefStoresTombstoneWithoutReviving(t *testing.T) {
	ctx := context.Background()
	store, clock := newSnapshotStore()
	svc := newSnapshotService(store, clock)

	uid := "uid-1"
	ref, err := svc.PutRef(ctx, "u1", api.SyncRefWrite{Name: "  第三章  ", CommitUid: &uid})
	if err != nil || ref.Name != "第三章" || ref.CommitUID != "uid-1" || !ref.DeletedAt.IsZero() {
		t.Fatalf("写入: %+v, %v", ref, err)
	}
	*clock = clock.Add(time.Hour)
	deleted := true
	tombstone, err := svc.PutRef(ctx, "u1", api.SyncRefWrite{Name: "第三章", Delete: &deleted})
	if err != nil || tombstone.DeletedAt.IsZero() {
		t.Fatalf("删除应留下墓碑: %+v, %v", tombstone, err)
	}
	// 写成时间早于删除时间：不复活，返回的仍是墓碑。
	*clock = tombstone.DeletedAt.Add(-time.Minute)
	late := "uid-late"
	kept, err := svc.PutRef(ctx, "u1", api.SyncRefWrite{Name: "第三章", CommitUid: &late})
	if err != nil || kept.DeletedAt.IsZero() {
		t.Fatalf("迟到的写入不应复活: %+v, %v", kept, err)
	}
	// 删除之后的写入复活。
	*clock = tombstone.DeletedAt.Add(time.Hour)
	revivedUID := "uid-revived"
	revived, err := svc.PutRef(ctx, "u1", api.SyncRefWrite{Name: "第三章", CommitUid: &revivedUID})
	if err != nil || !revived.DeletedAt.IsZero() || revived.CommitUID != "uid-revived" {
		t.Fatalf("删除之后的写入应复活: %+v, %v", revived, err)
	}
	// 名字超长、缺引用都是无效请求。
	if _, err := svc.PutRef(ctx, "u1", api.SyncRefWrite{Name: strings.Repeat("名", 31), CommitUid: &uid}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("超长名字应返回 ErrInvalid，得到 %v", err)
	}
	if _, err := svc.PutRef(ctx, "u1", api.SyncRefWrite{Name: "没有引用"}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("缺引用应返回 ErrInvalid，得到 %v", err)
	}
}
