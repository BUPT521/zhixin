package retention

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func newTestService(store Store, secret string) *Service {
	svc := NewService(store, []byte(secret), time.UTC)
	svc.now = func() time.Time { return time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC) }
	return svc
}

func TestHashInstallIsStableAndSecretBound(t *testing.T) {
	store := NewMemoryStore()
	first := newTestService(store, "a")
	second := newTestService(store, "b")

	const id = "0f8fad5b-d9cb-469f-a165-70867728950e"
	h1, err := first.hashInstall(id)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if len(h1) != 64 {
		t.Fatalf("哈希应为 64 位十六进制，得到 %q", h1)
	}
	again, _ := first.hashInstall(" " + id + " ")
	if again != h1 {
		t.Fatalf("两端空白应去掉且同一标识哈希稳定：%q %q", h1, again)
	}
	other, _ := second.hashInstall(id)
	if other == h1 {
		t.Fatal("换一个密钥应当得到不同的哈希，否则重启后无法区分新旧")
	}
}

func TestHashInstallRejectsUnsafeCharacters(t *testing.T) {
	svc := newTestService(NewMemoryStore(), "a")
	for _, id := range []string{
		"short",
		strings.Repeat("a", maxInstallRunes+1),
		"0f8fad5b d9cb 469f a165 70867728950e",
		"0f8fad5b-d9cb-469f-a165-70867728950e;drop",
		"安装标识安装标识安装标识安装标识",
	} {
		if _, err := svc.hashInstall(id); !errors.Is(err, ErrInvalid) {
			t.Fatalf("%q 应当被拒绝，得到 %v", id, err)
		}
	}
}

func TestRecordInstallUsesServerDay(t *testing.T) {
	store := NewMemoryStore()
	svc := newTestService(store, "a")
	ping := Ping{InstallID: "0f8fad5b-d9cb-469f-a165-70867728950e"}
	if err := svc.RecordInstall(context.Background(), ping); err != nil {
		t.Fatalf("record: %v", err)
	}
	// 日期由服务端的 now 与配置时区决定，客户端不带日期。
	if got := store.installCount(); got != 1 {
		t.Fatalf("应只保存一行，得到 %d", got)
	}
	var key [2]string
	for k := range store.installs {
		key = k
	}
	if key[1] != "2026-11-18" {
		t.Fatalf("应记在服务端自然日 2026-11-18，得到 %q", key[1])
	}
	if svc.today() != "2026-11-18" {
		t.Fatalf("today = %q", svc.today())
	}
}

func TestPruneRemovesOnlyRowsOutsideKeepWindow(t *testing.T) {
	store := NewMemoryStore()
	svc := newTestService(store, "a")
	ctx := context.Background()
	if err := store.MarkInstallActive(ctx, "old", "2026-05-01"); err != nil {
		t.Fatalf("seed old: %v", err)
	}
	if err := store.MarkInstallActive(ctx, "fresh", "2026-11-18"); err != nil {
		t.Fatalf("seed fresh: %v", err)
	}
	if err := store.MarkInstallActive(ctx, "edge", "2026-05-22"); err != nil {
		t.Fatalf("seed edge: %v", err)
	}

	if err := svc.Prune(ctx); err != nil {
		t.Fatalf("prune: %v", err)
	}
	if got := store.installCount(); got != 2 {
		t.Fatalf("保留期外的一行应被删除，留下 2 行，得到 %d", got)
	}
	if _, ok := store.installs[[2]string{"old", "2026-05-01"}]; ok {
		t.Fatal("2026-05-01 应被删除")
	}
	// 2026-11-18 往前 180 天是 2026-05-22，等于起点的那一天保留。
	if _, ok := store.installs[[2]string{"edge", "2026-05-22"}]; !ok {
		t.Fatal("保留期起点当天不应被删除")
	}
}

func TestRecordUserActiveWritesOncePerDay(t *testing.T) {
	store := NewMemoryStore()
	svc := newTestService(store, "a")
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		if err := svc.RecordUserActive(ctx, "u1"); err != nil {
			t.Fatalf("record: %v", err)
		}
	}
	if got := store.userDayCount(); got != 1 {
		t.Fatalf("同一天应只写一行，得到 %d", got)
	}

	svc.now = func() time.Time { return time.Date(2026, 11, 19, 8, 0, 0, 0, time.UTC) }
	if err := svc.RecordUserActive(ctx, "u1"); err != nil {
		t.Fatalf("record next day: %v", err)
	}
	if got := store.userDayCount(); got != 2 {
		t.Fatalf("第二天应再写一行，得到 %d", got)
	}
}

func TestRecordUserActiveRetriesAfterStoreFailure(t *testing.T) {
	store := &sometimesFailingStore{MemoryStore: NewMemoryStore()}
	svc := NewService(store, []byte("a"), time.UTC)
	ctx := context.Background()
	if err := svc.RecordUserActive(ctx, "u1"); err == nil {
		t.Fatal("第一次写失败应返回错误")
	}
	// 失败不缓存，下一次请求会再试并成功。
	if err := svc.RecordUserActive(ctx, "u1"); err != nil {
		t.Fatalf("第二次应成功：%v", err)
	}
}

// sometimesFailingStore 第一次写用户活跃时失败，之后成功。
type sometimesFailingStore struct {
	*MemoryStore
	failed bool
}

func (s *sometimesFailingStore) MarkUserActive(ctx context.Context, userID, day string) error {
	if !s.failed {
		s.failed = true
		return errors.New("db down")
	}
	return s.MemoryStore.MarkUserActive(ctx, userID, day)
}
