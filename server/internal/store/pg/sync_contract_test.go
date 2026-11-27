package pg

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// TestPostgresAppendReturnsSeqs 守住逐条序号与重复提交的原序号：新提交按顺序拿到
// head 之后的序号，重复提交回 sync_commit_seen 里记下的序号，整批重放不写入
// （ADR-0054）。
func TestPostgresAppendReturnsSeqs(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "seqs@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	mk := func(id string) syncsvc.Commit {
		after := json.RawMessage(`{}`)
		return syncsvc.Commit{
			Uid: id, Kind: "write", DeviceId: "d1", SchemaVersion: 27,
			Actor: "user", Action: "写入", CreatedAt: "2026-11-15 10:00:00",
			Changes: []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	first, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("a"), mk("b"), mk("c")}, syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{})
	if err != nil || first.Head != 3 || len(first.Seqs) != 3 ||
		first.Seqs[0] != 1 || first.Seqs[1] != 2 || first.Seqs[2] != 3 {
		t.Fatalf("新提交的逐条序号: %+v %v", first, err)
	}
	// 第二批里混一条重复的提交。
	second, err := st.Append(ctx, "u1", 3, []syncsvc.Commit{mk("b"), mk("d")}, syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{})
	if err != nil || second.Head != 4 || len(second.Seqs) != 2 || second.Seqs[0] != 2 || second.Seqs[1] != 4 {
		t.Fatalf("重复提交应回原序号: %+v %v", second, err)
	}
	// 整批重放：head 不变，逐条序号都是原来的。
	replay, err := st.Append(ctx, "u1", 3, []syncsvc.Commit{mk("a"), mk("b"), mk("c")}, syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{})
	if err != nil || replay.Head != 4 || len(replay.Seqs) != 3 || replay.Seqs[0] != 1 || replay.Seqs[2] != 3 {
		t.Fatalf("整批重放: %+v %v", replay, err)
	}
	commits, err := st.After(ctx, "u1", 0, 10, syncsvc.DefaultPullBytes)
	if err != nil || len(commits) != 4 {
		t.Fatalf("重放不应追加提交: %d %v", len(commits), err)
	}
	// 压缩删掉旧提交之后仍然回得出原序号。
	if _, err := st.RegisterSnapshot(ctx, "u1", syncsvc.Snapshot{
		Seq: 4, SHA256: strings.Repeat("a", 64), Digest: strings.Repeat("b", 64),
	}, syncsvc.CompactPolicy{Keep: time.Nanosecond, AllowDelete: true}); err != nil {
		t.Fatalf("登记快照: %v", err)
	}
	afterCompact, err := st.Append(ctx, "u1", 4, []syncsvc.Commit{mk("a")}, syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{})
	if err != nil || afterCompact.Head != 4 || afterCompact.Seqs[0] != 1 {
		t.Fatalf("压缩之后重放应回原序号: %+v %v", afterCompact, err)
	}
}

// TestPostgresTableDigestsRoundTrip 守住分表摘要的落库与读回：带摘要的提交原样
// 保存并原样返回，没有带的提交读回时保持为空（ADR-0054）。
func TestPostgresTableDigestsRoundTrip(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "tables@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	after := json.RawMessage(`{}`)
	tables := map[string]string{
		"plan_item": strings.Repeat("1", 64),
		"memory":    strings.Repeat("2", 64),
	}
	commits := []syncsvc.Commit{
		{
			Uid: "a", Kind: "write", DeviceId: "d1", SchemaVersion: 27, Actor: "user", Action: "写入",
			CreatedAt: "2026-11-15 10:00:00",
			Changes:   []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		},
		{
			Uid: "b", Kind: "maintenance", DeviceId: "d1", SchemaVersion: 27, Actor: "user", Action: "写入",
			CreatedAt:    "2026-11-15 10:00:00",
			Changes:      []syncsvc.Change{{Table: "memory", RowKey: "2", Op: "insert", After: &after}},
			TableDigests: &tables,
		},
	}
	if _, err := st.Append(ctx, "u1", 0, commits, syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{}); err != nil {
		t.Fatalf("append: %v", err)
	}
	pulled, err := st.After(ctx, "u1", 0, 10, syncsvc.DefaultPullBytes)
	if err != nil || len(pulled) != 2 {
		t.Fatalf("pull: %d %v", len(pulled), err)
	}
	// 提交类型照原样落库与读回（审查 V18）。
	if pulled[0].Kind != "write" || pulled[1].Kind != "maintenance" {
		t.Fatalf("拉取返回的 kind 不对: %q %q", pulled[0].Kind, pulled[1].Kind)
	}
	if pulled[0].TableDigests != nil {
		t.Fatalf("没有分表摘要的提交读回时应为空: %+v", *pulled[0].TableDigests)
	}
	got := pulled[1].TableDigests
	if got == nil || (*got)["plan_item"] != tables["plan_item"] || (*got)["memory"] != tables["memory"] || len(*got) != 2 {
		t.Fatalf("分表摘要应原样读回: %+v", got)
	}
}

// TestPostgresDevicePosition 守住设备位置的落库：拉取按 position 取较大值、不超过
// head，推送之后有新提交时推进到 head、整批重放只按 base 推进（ADR-0054）。
func TestPostgresDevicePosition(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "pos@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	after := json.RawMessage(`{}`)
	mk := func(id string) syncsvc.Commit {
		return syncsvc.Commit{
			Uid: id, Kind: "write", DeviceId: "d1", SchemaVersion: 27, Actor: "user", Action: "写入",
			CreatedAt: "2026-11-15 10:00:00",
			Changes:   []syncsvc.Change{{Table: "memory", RowKey: "1", Op: "insert", After: &after}},
		}
	}
	if _, err := st.Append(ctx, "u1", 0, []syncsvc.Commit{mk("a"), mk("b"), mk("c")}, syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{}); err != nil {
		t.Fatalf("append: %v", err)
	}
	// head 是 3，位置写 10 也要减到 3。
	if err := st.TouchDevice(ctx, "u1", "d1", true, 10); err != nil {
		t.Fatalf("记录设备: %v", err)
	}
	devices, err := st.Devices(ctx, "u1", 50)
	if err != nil || len(devices) != 1 || devices[0].SyncedSeq != 3 || !devices[0].SnapshotCapable {
		t.Fatalf("位置不应超过 head: %+v %v", devices, err)
	}
	// 拉取按 position 取较大值：写 1 不会让位置倒退。
	if err := st.TouchDevice(ctx, "u1", "d1", true, 1); err != nil {
		t.Fatalf("记录设备: %v", err)
	}
	if devices, err = st.Devices(ctx, "u1", 50); err != nil || devices[0].SyncedSeq != 3 {
		t.Fatalf("位置不应倒退: %+v %v", devices, err)
	}
	// 整批重放：只按 base 取较大值，不跳到 head。
	claim := &syncsvc.DeviceClaim{DeviceID: "d1", SnapshotCapable: true}
	if _, err := st.Append(ctx, "u1", 1, []syncsvc.Commit{mk("a"), mk("b"), mk("c")},
		syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{Touch: claim}); err != nil {
		t.Fatalf("重放: %v", err)
	}
	if devices, err = st.Devices(ctx, "u1", 50); err != nil || devices[0].SyncedSeq != 3 {
		t.Fatalf("整批重放不应改变位置: %+v %v", devices, err)
	}
	// 有新提交时随 Append 一起推进到当前 head。
	if _, err := st.Append(ctx, "u1", 3, []syncsvc.Commit{mk("d")},
		syncsvc.CompactPolicy{}, syncsvc.DeviceRoster{Touch: claim}); err != nil {
		t.Fatalf("append: %v", err)
	}
	if devices, err = st.Devices(ctx, "u1", 50); err != nil || devices[0].SyncedSeq != 4 {
		t.Fatalf("有新提交时应推进到 head: %+v %v", devices, err)
	}
	// 常规压缩的位置门槛取活跃设备的最小位置。
	floor, ok, err := st.ActiveMinSyncedSeq(ctx, "u1", time.Now().UTC().Add(-time.Hour))
	if err != nil || !ok || floor != 4 {
		t.Fatalf("活跃设备的最小位置: %d %v %v", floor, ok, err)
	}
	if _, ok, err = st.ActiveMinSyncedSeq(ctx, "u1", time.Now().UTC().Add(time.Hour)); err != nil || ok {
		t.Fatalf("窗口内没有设备时不应有上限: %v %v", ok, err)
	}
}

// TestPostgresRefs 守住命名版本的落库：写入、覆盖、墓碑、比删除时间更早的写入不
// 复活、上限与清空云端数据时整表清掉（ADR-0054）。
func TestPostgresRefs(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "refs@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	written, err := st.PutRef(ctx, "u1", syncsvc.Ref{Name: "第三章", CommitUID: "uid-1", Note: "备注", UpdatedAt: now})
	if err != nil || !written {
		t.Fatalf("写入: %v %v", written, err)
	}
	// 后写覆盖先写。
	written, err = st.PutRef(ctx, "u1", syncsvc.Ref{Name: "第三章", CommitUID: "uid-2", UpdatedAt: now.Add(time.Minute)})
	if err != nil || !written {
		t.Fatalf("覆盖: %v %v", written, err)
	}
	refs, err := st.Refs(ctx, "u1")
	if err != nil || len(refs) != 1 || refs[0].CommitUID != "uid-2" || refs[0].Note != "" {
		t.Fatalf("覆盖之后: %+v %v", refs, err)
	}
	// 删除留墓碑。
	written, err = st.PutRef(ctx, "u1", syncsvc.Ref{Name: "第三章", UpdatedAt: now.Add(2 * time.Minute), DeletedAt: now.Add(2 * time.Minute)})
	if err != nil || !written {
		t.Fatalf("删除: %v %v", written, err)
	}
	refs, err = st.Refs(ctx, "u1")
	if err != nil || len(refs) != 1 || refs[0].DeletedAt.IsZero() {
		t.Fatalf("墓碑: %+v %v", refs, err)
	}
	deletedAt := refs[0].DeletedAt
	// 比删除时间更早的写入不复活。
	written, err = st.PutRef(ctx, "u1", syncsvc.Ref{Name: "第三章", CommitUID: "uid-late", UpdatedAt: deletedAt.Add(-time.Minute)})
	if err != nil || written {
		t.Fatalf("迟到的写入不应复活: %v %v", written, err)
	}
	if refs, err = st.Refs(ctx, "u1"); err != nil || refs[0].DeletedAt.IsZero() {
		t.Fatalf("迟到的写入不应改变墓碑: %+v %v", refs, err)
	}
	written, err = st.PutRef(ctx, "u1", syncsvc.Ref{
		Name: "第三章", CommitUID: "uid-late-offline", UpdatedAt: deletedAt.Add(time.Minute),
		SourceUpdatedAt: deletedAt.Add(-time.Minute),
	})
	if err != nil || written {
		t.Fatalf("晚到的离线旧编辑不应复活: %v %v", written, err)
	}
	// 删除之后的写入复活，墓碑清空。
	written, err = st.PutRef(ctx, "u1", syncsvc.Ref{Name: "第三章", CommitUID: "uid-revived", UpdatedAt: deletedAt.Add(time.Minute)})
	if err != nil || !written {
		t.Fatalf("删除之后的写入应复活: %v %v", written, err)
	}
	refs, err = st.Refs(ctx, "u1")
	if err != nil || len(refs) != 1 || !refs[0].DeletedAt.IsZero() || refs[0].CommitUID != "uid-revived" {
		t.Fatalf("复活之后: %+v %v", refs, err)
	}
	// 上限：填满 200 个未删除的名字之后再写新的名字会被拒绝。
	for i := 0; ; i++ {
		written, err = st.PutRef(ctx, "u1", syncsvc.Ref{
			Name: "版本-" + intText(i), CommitUID: "uid-fill",
			UpdatedAt: now.Add(time.Duration(i+10) * time.Millisecond),
		})

		if errors.Is(err, syncsvc.ErrRefLimit) || !written {
			break
		}
		if err != nil {
			t.Fatalf("填充第 %d 个名字: %v", i, err)
		}
		if i > 300 {
			t.Fatal("没有在 300 次之内碰到上限")
		}
	}
	written, err = st.PutRef(ctx, "u1", syncsvc.Ref{
		Name: "第三章", CommitUID: "uid-existing", UpdatedAt: deletedAt.Add(2 * time.Minute),
	})
	if err != nil || !written {
		t.Fatalf("达到上限仍可更新已有名字: %v %v", written, err)
	}
	// 清空云端数据把整表清掉，墓碑一并清掉。
	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if refs, err = st.Refs(ctx, "u1"); err != nil || len(refs) != 0 {
		t.Fatalf("清空之后命名版本应为空: %+v %v", refs, err)
	}
}

// intText 把整数写成十进制文本。
func intText(value int) string {
	if value == 0 {
		return "0"
	}
	var digits []byte
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}

// TestPostgresResetClearsDevicePositions 守住清空云端数据的范围：设备名册（含位置）
// 与附件的回收标记一并清掉，附件的索引行仍由附件存储另行清（ADR-0047、ADR-0054）。
func TestPostgresResetClearsDevicePositions(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	if err := createAccount(ctx, st, auth.User{ID: "u1", PasswordHash: "h"}, "resetpos@b.cn"); err != nil {
		t.Fatalf("user: %v", err)
	}
	bs := NewBlobStore(st)
	sha := strings.Repeat("a", 64)
	body := []byte("snapshot bytes")
	if err := bs.Save(ctx, "u1", sha, int64(len(body)), strings.NewReader(string(body))); err != nil {
		t.Fatalf("写入附件字节: %v", err)
	}
	if _, err := bs.Reserve(ctx, "u1", sha, int64(len(body)), 0); err != nil {
		t.Fatalf("写入附件索引: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `UPDATE attachment SET orphaned_at = now() WHERE user_id = $1`, "u1"); err != nil {
		t.Fatalf("写回收标记: %v", err)
	}
	if err := st.TouchDevice(ctx, "u1", "d1", true, 5); err != nil {
		t.Fatalf("记录设备: %v", err)
	}
	if err := st.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if devices, err := st.Devices(ctx, "u1", 50); err != nil || len(devices) != 0 {
		t.Fatalf("清空之后名册应为空: %+v %v", devices, err)
	}
	orphans, err := st.OrphanedAttachmentsBefore(ctx, "u1", time.Now().UTC().Add(24*time.Hour))
	if err != nil || len(orphans) != 0 {
		t.Fatalf("清空之后不应再有回收标记: %v %v", orphans, err)
	}
	// 附件索引行的清理由附件存储负责，Reset 不动它。
	var rows int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM attachment WHERE user_id = $1`, "u1").Scan(&rows); err != nil {
		t.Fatalf("清点附件索引行: %v", err)
	}
	if rows != 1 {
		t.Fatalf("Reset 不应删除附件索引行，剩 %d 行", rows)
	}
}
