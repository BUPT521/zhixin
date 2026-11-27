package server

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/config"
)

// 本文件核对 P2 加固里跨模块的两条规则：注册的实例级上限在接入层生效，
// 以及未确认邮箱的账号在服务启动的第一次每日清理里按保留期删除。代次、对账与
// 刷新事务的实现细节在各自包的用例里。

// TestRegisterGlobalBudget 核对注册的实例级上限：桶用完之后即使换邮箱也回 429，
// 且被挡下的请求没有写入账号（用它登录得到凭据错误，而不是登录成功）。
func TestRegisterGlobalBudget(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_REGISTER_GLOBAL_RATE":  "0.0001",
		"ZHIXIN_REGISTER_GLOBAL_BURST": "2",
	})
	credentials := func(i int) map[string]string {
		return map[string]string{"identifier": "reg" + string(rune('a'+i)) + "@b.cn", "password": "password1"}
	}
	for i := 0; i < 2; i++ {
		if code := h.json("POST", "/v1/auth/register", "", credentials(i), nil); code != http.StatusCreated {
			t.Fatalf("桶容量 2 之内第 %d 个注册应成功，得到 %d", i+1, code)
		}
	}
	resp := h.do("POST", "/v1/auth/register", "", bytes.NewReader(mustJSON(t, credentials(2))),
		map[string]string{"Content-Type": "application/json"})
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("超出实例级上限应回 429，得到 %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Retry-After"); got == "" {
		t.Fatal("429 应带 Retry-After")
	}
	// 被挡下的注册不应留下账号：登录得到凭据错误，而不是登录成功。
	if code := h.json("POST", "/v1/auth/login", "", credentials(2), nil); code != http.StatusUnauthorized {
		t.Fatalf("被限流的注册不应写入账号，登录得到 %d", code)
	}
}

// TestStartupPrunesOldUnverifiedAccounts 核对装配把保留期交给了每日清理：启动时
// 先清一次，超过保留期、没有任何已验证登录方式的账号被删除，刚注册的与已确认的
// 账号保留。
func TestStartupPrunesOldUnverifiedAccounts(t *testing.T) {
	cfg, err := config.Load(func(key string) string {
		if key == "ZHIXIN_UNVERIFIED_KEEP_DAYS" {
			return "7"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	stores := MemoryStores(cfg, log)
	store, ok := stores.Auth.(*auth.MemoryStore)
	if !ok {
		t.Fatalf("内存装配应使用 MemoryStore，得到 %T", stores.Auth)
	}
	now := time.Now()
	ctx := context.Background()
	seed := []struct {
		id, email string
		created   time.Time
		verified  bool
	}{
		{"stale", "stale@b.cn", now.Add(-8 * 24 * time.Hour), false},
		{"fresh", "fresh@b.cn", now.Add(-time.Hour), false},
		{"verified", "verified@b.cn", now.Add(-30 * 24 * time.Hour), true},
	}
	for _, account := range seed {
		u := auth.User{ID: account.id, PasswordHash: "h", CreatedAt: account.created}
		ident := auth.Identity{
			ID: account.id + "-email", UserID: account.id, Kind: auth.KindEmail,
			Identifier: account.email, CreatedAt: account.created,
		}
		if account.verified {
			ident.VerifiedAt = now.Add(-29 * 24 * time.Hour)
		}
		if err := store.CreateAccount(ctx, u, ident); err != nil {
			t.Fatalf("seed %s: %v", account.id, err)
		}
	}
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	Build(runCtx, cfg, stores, log)

	// 每日清理在启动后的 goroutine 里先跑一次，等它把过期账号删掉。
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := store.UserByID(ctx, "stale"); errors.Is(err, auth.ErrNotFound) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("启动清理没有删除超过保留期的未验证账号")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := store.UserByID(ctx, "fresh"); err != nil {
		t.Fatalf("保留期内的账号不应删除：%v", err)
	}
	if _, err := store.UserByID(ctx, "verified"); err != nil {
		t.Fatalf("已确认的账号不应删除：%v", err)
	}
}
