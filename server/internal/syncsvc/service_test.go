package syncsvc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
)

func testCommit(id string, schema int) Commit {
	after := json.RawMessage(`{"content":"x"}`)
	return Commit{
		Uid:           id,
		Kind:          api.Write,
		DeviceId:      "device-a",
		SchemaVersion: schema,
		Actor:         api.User,
		Action:        "create",
		CreatedAt:     "2026-11-15 10:00:00",
		Changes: []Change{{
			Table:  "memory",
			RowKey: "1",
			Op:     api.Insert,
			After:  &after,
		}},
	}
}

func TestServicePushIsLinearAndIdempotent(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)

	result, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)}, DeviceRoster{})
	if err != nil || result.Head != 2 || len(result.Seqs) != 2 || result.Seqs[0] != 1 || result.Seqs[1] != 2 {
		t.Fatalf("push: %+v, err %v", result, err)
	}
	// A retried batch after a lost response is ignored and answers with the
	// sequence numbers the commits already hold.
	if result, err = svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27)}, DeviceRoster{}); err != nil || result.Head != 2 || len(result.Seqs) != 1 || result.Seqs[0] != 1 {
		t.Fatalf("replay: %+v, err %v", result, err)
	}
	// A new commit on a stale base must pull first.
	if _, err = svc.Push(ctx, "u1", 0, []Commit{testCommit("r3", 27)}, DeviceRoster{}); !errors.Is(err, ErrHeadMoved) {
		t.Fatalf("stale push: want ErrHeadMoved, got %v", err)
	}
}

func TestServiceValidatesBatchAndPage(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)

	if _, err := svc.Push(ctx, "u1", 0, nil, DeviceRoster{}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("empty batch: want ErrInvalid, got %v", err)
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("old", 25)}, DeviceRoster{}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("old schema: want ErrInvalid, got %v", err)
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27)}, DeviceRoster{}); err != nil {
		t.Fatalf("push: %v", err)
	}

	after := int64(-1)
	if _, err := svc.Pull(ctx, "u1", &after, nil); !errors.Is(err, ErrInvalid) {
		t.Fatalf("negative after: want ErrInvalid, got %v", err)
	}
	limit := 0
	if _, err := svc.Pull(ctx, "u1", nil, &limit); !errors.Is(err, ErrInvalid) {
		t.Fatalf("zero limit: want ErrInvalid, got %v", err)
	}
	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 1 || page.Head != 1 || page.HasMore {
		t.Fatalf("pull = %+v, %v", page, err)
	}
}

// TestServicePullStopsAtByteLimit 守住拉取分页的响应字节上限：累计序列化字节
// 超过上限时截断本页并让 has_more 为真，下一页从截断处继续，拉完不再有更多。
// 页预算的下限是单条提交上限，所以用两条都接近单条上限的提交构造截断。
func TestServicePullStopsAtByteLimit(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)
	big := func(id string) Commit {
		c := testCommit(id, 27)
		after := json.RawMessage(fmt.Sprintf(`{"content":%q}`, strings.Repeat("x", 1200*1024)))
		c.Changes[0].After = &after
		return c
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{big("r1"), big("r2")}, DeviceRoster{}); err != nil {
		t.Fatalf("push: %v", err)
	}
	// 页预算配置为 1 字节，会被抬到下限 MaxCommitBytes：一页只装得下一条。
	svc.SetMaxPullBytes(1)

	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 1 || !page.HasMore {
		t.Fatalf("first limited page = %+v, %v", page, err)
	}
	after := *page.Commits[0].Seq
	page, err = svc.Pull(ctx, "u1", &after, nil)
	if err != nil || len(page.Commits) != 1 || page.HasMore {
		t.Fatalf("last page = %+v, %v", page, err)
	}
}

// TestServicePullBudgetLowerBound 守住拉取页预算的下限（S12）：配置小于单条提交
// 上限时抬到 MaxCommitBytes，已经存入的提交不会因为页预算过小而永远返回 413。
func TestServicePullBudgetLowerBound(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27)}, DeviceRoster{}); err != nil {
		t.Fatalf("push: %v", err)
	}

	svc.SetMaxPullBytes(1)
	if svc.maxPullBytes != MaxCommitBytes {
		t.Fatalf("页预算 = %d，want 抬到下限 %d", svc.maxPullBytes, MaxCommitBytes)
	}
	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 1 || page.Head != 1 {
		t.Fatalf("低于下限的配置不应让已有提交拉不下来: %+v, %v", page, err)
	}
}

// TestServicePushSizesByCommitNotPage 守住提交大小的判断口径：单条提交只看
// MaxCommitBytes，整批只看 MaxPushBytes，一页拉取的字节预算不参与。把页预算调小
// 之后普通提交仍然写得进去，超过单条上限的提交照旧拒绝。
func TestServicePushSizesByCommitNotPage(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)
	// 页预算调到 1 字节（会被抬到 MaxCommitBytes 下限）：它只决定一页取多少条，
	// 不该把能存的提交判成太大。
	svc.SetMaxPullBytes(1)

	result, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)}, DeviceRoster{})
	if err != nil || result.Head != 2 {
		t.Fatalf("页预算不应限制提交大小: %+v, %v", result, err)
	}

	big := testCommit("big", 27)
	after := json.RawMessage(fmt.Sprintf(`{"content":%q}`, strings.Repeat("x", MaxCommitBytes)))
	big.Changes[0].After = &after
	if _, err := svc.Push(ctx, "u1", 2, []Commit{big}, DeviceRoster{}); !errors.Is(err, ErrPushTooLarge) {
		t.Fatalf("超过单条上限应返回 ErrPushTooLarge，得到 %v", err)
	}
}

// TestServiceResetClearsLog 守住重置的范围：只清指定账号的序列并把 head 归零，
// 另一个账号不受影响；重置之后从 0 重新推送可以正常分配序号，空序列再重置一次
// 不算错误。
func TestServiceResetClearsLog(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)

	if r, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)}, DeviceRoster{}); err != nil || r.Head != 2 {
		t.Fatalf("push u1: %+v, err %v", r, err)
	}
	if r, err := svc.Push(ctx, "u2", 0, []Commit{testCommit("other", 27)}, DeviceRoster{}); err != nil || r.Head != 1 {
		t.Fatalf("push u2: %+v, err %v", r, err)
	}

	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if state, err := svc.State(ctx, "u1"); err != nil || state.Head != 0 {
		t.Fatalf("head after reset = %d, %v", state.Head, err)
	}
	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 0 || page.Head != 0 || page.HasMore {
		t.Fatalf("pull after reset = %+v, %v", page, err)
	}
	// 重置之后序号从 1 重新开始。
	if r, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r3", 27)}, DeviceRoster{}); err != nil || r.Head != 1 {
		t.Fatalf("push after reset: %+v, err %v", r, err)
	}

	if state, err := svc.State(ctx, "u2"); err != nil || state.Head != 1 {
		t.Fatalf("other account head = %d, %v", state.Head, err)
	}

	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("second reset: %v", err)
	}
}

// TestServiceKeepsOptionalStateDigest 守住契约里的可选整库摘要：服务端原样保存、
// 不解析，拉取时原样带回；没有带的提交保持为空，客户端据此跳过比较（改进方案
// 3.5）。内存实现直接保存 Commit，这里一并确认序号重写不会丢掉这个字段。
func TestServiceKeepsOptionalStateDigest(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)
	digest := strings.Repeat("a", 64)
	withDigest := testCommit("r2", 27)
	withDigest.StateDigest = &digest

	result, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), withDigest}, DeviceRoster{})
	if err != nil || result.Head != 2 {
		t.Fatalf("push: %+v, err %v", result, err)
	}
	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 2 {
		t.Fatalf("pull = %+v, %v", page, err)
	}
	if page.Commits[0].StateDigest != nil {
		t.Fatalf("没有带摘要的提交不该凭空多出字段: %+v", page.Commits[0].StateDigest)
	}
	if got := page.Commits[1].StateDigest; got == nil || *got != digest {
		t.Fatalf("摘要没有原样带回: %v", got)
	}
	if seq := page.Commits[1].Seq; seq == nil || *seq != 2 {
		t.Fatalf("seq 由服务端分配: %v", page.Commits[1].Seq)
	}
}
