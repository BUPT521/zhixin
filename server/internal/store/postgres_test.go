package store_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/store"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

func TestPostgresStores(t *testing.T) {
	dsn := os.Getenv("ZHIXIN_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set ZHIXIN_TEST_DATABASE_URL to exercise the PostgreSQL stores")
	}
	ctx := t.Context()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid test database URL")
	}
	root, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	namespace := fmt.Sprintf("zhixin_test_%d", time.Now().UnixNano())
	if _, err := root.Exec(ctx, "CREATE SCHEMA "+namespace); err != nil {
		t.Fatal(err)
	}
	defer root.Exec(context.Background(), "DROP SCHEMA "+namespace+" CASCADE")
	cfg.ConnConfig.RuntimeParams["search_path"] = namespace
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	ddl, err := os.ReadFile("schema.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, string(ddl)); err != nil {
		t.Fatal(err)
	}

	objects, err := os.OpenRoot(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer objects.Close()
	accounts := store.Accounts(pool)
	log := store.SyncLog(pool)
	snapshots := store.Backups(pool, objects)
	quota := store.Quota(pool)
	svc := auth.NewService(accounts, time.Hour, 2*time.Hour)
	svc.OnAccountDelete(log.DeleteUser)
	svc.OnAccountDelete(snapshots.DeleteUser)
	svc.OnAccountDelete(quota.DeleteUser)

	tokens, err := svc.Register(ctx, "learner@example.test", "local-test-password", "test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Register(ctx, "learner@example.test", "local-test-password", "test"); !errors.Is(err, auth.ErrEmailTaken) {
		t.Fatalf("duplicate registration: %v", err)
	}
	refreshed, err := svc.Refresh(ctx, tokens.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Authenticate(ctx, tokens.AccessToken); !errors.Is(err, auth.ErrInvalidToken) {
		t.Fatalf("old access token: %v", err)
	}
	principal, err := svc.Authenticate(ctx, refreshed.AccessToken)
	if err != nil {
		t.Fatal(err)
	}

	candidate := func(id string) syncsvc.Commit {
		return syncsvc.Commit{
			RequestID: id, DeviceID: "device", SchemaVersion: 26, Actor: "user",
			Action: "test", CreatedAt: "2026-11-15 00:00:00",
			Changes: []syncsvc.Change{{Table: "message", RowKey: "1", Op: "insert", After: []byte(`{"content":"fixture"}`)}},
		}
	}
	var group sync.WaitGroup
	results := make(chan error, 2)
	for _, id := range []string{"request-one", "request-two"} {
		group.Go(func() {
			_, err := log.Append(ctx, tokens.UserID, 0, []syncsvc.Commit{candidate(id)})
			results <- err
		})
	}
	group.Wait()
	close(results)
	successes, conflicts := 0, 0
	for err := range results {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, syncsvc.ErrHeadMoved):
			conflicts++
		default:
			t.Fatal(err)
		}
	}
	if successes != 1 || conflicts != 1 {
		t.Fatalf("appended=%d conflict=%d", successes, conflicts)
	}
	rows, err := log.After(ctx, tokens.UserID, 0, 10)
	if err != nil || len(rows) != 1 || rows[0].Seq != 1 || len(rows[0].Changes) != 1 {
		t.Fatalf("sync rows=%#v err=%v", rows, err)
	}
	if head, err := log.Append(ctx, tokens.UserID, 0, rows); head != 1 || err != nil {
		t.Fatalf("replayed head=%d err=%v", head, err)
	}

	const day = "2026-11-15"
	for _, tokensUsed := range []int64{7, 11} {
		if err := quota.Add(ctx, tokens.UserID, day, tokensUsed); err != nil {
			t.Fatal(err)
		}
	}
	if used, err := quota.Used(ctx, tokens.UserID, day); used != 18 || err != nil {
		t.Fatalf("used=%d err=%v", used, err)
	}

	for i, id := range []string{"backup-a", "backup-b"} {
		meta := backup.Meta{ID: id, SHA256: "fixture", Size: 4, SchemaVersion: 26, CreatedAt: time.Now().Add(time.Duration(i) * time.Minute)}
		if err := snapshots.Put(ctx, tokens.UserID, meta, strings.NewReader("test"), 1); err != nil {
			t.Fatal(err)
		}
	}
	if _, rc, err := snapshots.Open(ctx, tokens.UserID, "backup-a"); !errors.Is(err, backup.ErrNotFound) {
		if rc != nil {
			rc.Close()
		}
		t.Fatalf("expired backup: %v", err)
	}
	_, rc, err := snapshots.Open(ctx, tokens.UserID, "backup-b")
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(rc)
	rc.Close()
	if err != nil || string(data) != "test" {
		t.Fatalf("backup data=%q err=%v", data, err)
	}

	if err := svc.DeleteAccount(ctx, principal); err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.UserByID(ctx, tokens.UserID); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("deleted account: %v", err)
	}
	if rows, err := log.After(ctx, tokens.UserID, 0, 10); len(rows) != 0 || err != nil {
		t.Fatalf("deleted sync rows=%d err=%v", len(rows), err)
	}
	if used, err := quota.Used(ctx, tokens.UserID, day); used != 0 || err != nil {
		t.Fatalf("deleted quota=%d err=%v", used, err)
	}
	items, err := os.ReadDir(objects.Name())
	if err != nil || len(items) != 0 {
		t.Fatalf("snapshot objects=%d err=%v", len(items), err)
	}
}
