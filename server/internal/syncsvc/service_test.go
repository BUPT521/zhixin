package syncsvc

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
)

func testCommit(id string, schema int) Commit {
	after := json.RawMessage(`{"content":"x"}`)
	return Commit{
		RequestId:     id,
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

	head, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)})
	if err != nil || head != 2 {
		t.Fatalf("push: head %d, err %v", head, err)
	}
	// A retried batch after a lost response is ignored.
	if head, err = svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27)}); err != nil || head != 2 {
		t.Fatalf("replay: head %d, err %v", head, err)
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

// TestServiceResetClearsLog 守住重置的范围：只清指定账号的序列并把 head 归零，
// 另一个账号不受影响；重置之后从 0 重新推送可以正常分配序号，空序列再重置一次
// 不算错误。
func TestServiceResetClearsLog(t *testing.T) {
	ctx := context.Background()
	svc := NewService(NewMemoryStore(), 27)

	if head, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r1", 27), testCommit("r2", 27)}); err != nil || head != 2 {
		t.Fatalf("push u1: head %d, err %v", head, err)
	}
	if head, err := svc.Push(ctx, "u2", 0, []Commit{testCommit("other", 27)}); err != nil || head != 1 {
		t.Fatalf("push u2: head %d, err %v", head, err)
	}

	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("reset: %v", err)
	}
	if head, err := svc.Head(ctx, "u1"); err != nil || head != 0 {
		t.Fatalf("head after reset = %d, %v", head, err)
	}
	page, err := svc.Pull(ctx, "u1", nil, nil)
	if err != nil || len(page.Commits) != 0 || page.Head != 0 || page.HasMore {
		t.Fatalf("pull after reset = %+v, %v", page, err)
	}
	// 重置之后序号从 1 重新开始。
	if head, err := svc.Push(ctx, "u1", 0, []Commit{testCommit("r3", 27)}); err != nil || head != 1 {
		t.Fatalf("push after reset: head %d, err %v", head, err)
	}

	if head, err := svc.Head(ctx, "u2"); err != nil || head != 1 {
		t.Fatalf("other account head = %d, %v", head, err)
	}

	if err := svc.Reset(ctx, "u1"); err != nil {
		t.Fatalf("second reset: %v", err)
	}
}
