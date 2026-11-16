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
