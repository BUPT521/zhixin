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

	result, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)})
	if err != nil || result.Head != 2 || len(result.Seqs) != 2 || result.Seqs[0] != 1 || result.Seqs[1] != 2 {
		t.Fatalf("push: %+v, err %v", result, err)
	}
	// A retried batch after a lost response is ignored and answers with the
	// sequence numbers the commits already hold.
	if result, err = svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27)}); err != nil || result.Head != 2 || len(result.Seqs) != 1 || result.Seqs[0] != 1 {
		t.Fatalf("replay: %+v, err %v", result, err)
	}
	// A new commit on a stale base must pull first.
	if _, err = svc.Push(ctx, "u1", 0, []Commit{testCommit("r3", 27)}); !errors.Is(err, ErrHeadMoved) {
		t.Fatalf("stale push: want ErrHeadMoved, got %v", err)
	}
}

func TestServiceValidatesBatchAndPage(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)

	if _, err := svc.Push(ctx, "u1", 0, nil); !errors.Is(err, ErrInvalid) {
		t.Fatalf("empty batch: want ErrInvalid, got %v", err)
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("old", 25)}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("old schema: want ErrInvalid, got %v", err)
	}
	if _, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27)}); err != nil {
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
// 超过上限时截断本页并让 has_more 为真，下一页从截断处继续，拉完不再有更多；
// 单条提交超过上限时返回错误，客户端可以停止重试当前游标。
func TestServicePullStopsAtByteLimit(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)
	batch := make([]Commit, 0, 5)
	for i := range 5 {
		batch = append(batch, testCommit(fmt.Sprintf("r%d", i), 27))
	}
	if _, err := svc.Push(ctx, "u1", 0, batch); err != nil {
		t.Fatalf("push: %v", err)
	}

	// 先不限字节拉一整页，量出两条提交的累计字节作为上限。
	all, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(all.Commits) != 5 {
		t.Fatalf("pull all = %+v, %v", all, err)
	}
	first, err := json.Marshal(all.Commits[0])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	second, err := json.Marshal(all.Commits[1])
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	svc.SetMaxPullBytes(int64(len(first) + len(second)))

	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 2 || !page.HasMore {
		t.Fatalf("first limited page = %+v, %v", page, err)
	}
	after := *page.Commits[1].Seq
	page, err = svc.Pull(ctx, "u1", &after, nil)
	if err != nil || len(page.Commits) != 2 || !page.HasMore {
		t.Fatalf("second limited page = %+v, %v", page, err)
	}
	after = *page.Commits[1].Seq
	page, err = svc.Pull(ctx, "u1", &after, nil)
	if err != nil || len(page.Commits) != 1 || page.HasMore {
		t.Fatalf("last page = %+v, %v", page, err)
	}

	// 单条超过上限时停止分页。
	svc.SetMaxPullBytes(1)
	if page, err = svc.Pull(ctx, "u1", nil, nil); !errors.Is(err, ErrPullTooLarge) {
		t.Fatalf("oversized single commit = %+v, %v", page, err)
	}
}

// TestServiceResetClearsLog 守住重置的范围：只清指定账号的序列并把 head 归零，
// 另一个账号不受影响；重置之后从 0 重新推送可以正常分配序号，空序列再重置一次
// 不算错误。
func TestServiceResetClearsLog(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)

	if r, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)}); err != nil || r.Head != 2 {
		t.Fatalf("push u1: %+v, err %v", r, err)
	}
	if r, err := svc.Push(ctx, "u2", 0, []Commit{testCommit("other", 27)}); err != nil || r.Head != 1 {
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
	if r, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r3", 27)}); err != nil || r.Head != 1 {
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

	result, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), withDigest})
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
