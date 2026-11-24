package pg

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
)

// TestAPIKeyStore 覆盖 api_key 的读写与撤销语义：撤销之后按摘要查不到、列表
// 仍然保留这一行、只认自己账号名下的密钥、删号随外键级联（ADR-0063）。
func TestAPIKeyStore(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	user := auth.User{ID: "user-key", PasswordHash: "hash"}
	if err := createAccount(ctx, st, user, "key@b.cn"); err != nil {
		t.Fatalf("create account: %v", err)
	}
	other := auth.User{ID: "user-other", PasswordHash: "hash"}
	if err := createAccount(ctx, st, other, "other@b.cn"); err != nil {
		t.Fatalf("create other: %v", err)
	}

	key := auth.APIKey{ID: "key-1", UserID: user.ID, Name: "脚本", Prefix: "zx_AbCdEfGh"}
	if err := st.CreateKey(ctx, key, "hash-1", 20); err != nil {
		t.Fatalf("create key: %v", err)
	}

	keys, err := st.KeysByUser(ctx, user.ID)
	if err != nil || len(keys) != 1 {
		t.Fatalf("list keys: %+v %v", keys, err)
	}
	if keys[0].ID != "key-1" || keys[0].Name != "脚本" || keys[0].Prefix != "zx_AbCdEfGh" || keys[0].Revoked {
		t.Fatalf("列表项不对：%+v", keys[0])
	}
	if !keys[0].LastUsedAt.IsZero() {
		t.Fatalf("没用过时不应有最近使用时间：%v", keys[0].LastUsedAt)
	}

	got, err := st.KeyByHash(ctx, "hash-1")
	if err != nil || got.ID != "key-1" || got.ContactVerified {
		t.Fatalf("按摘要查询：%+v %v", got, err)
	}

	// 登录方式确认之后，密钥读到同一个“已验证”口径。
	ident, err := st.IdentityByIdentifier(ctx, auth.KindEmail, "key@b.cn")
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	if err := st.SetIdentityVerified(ctx, user.ID, ident.ID, time.Now()); err != nil {
		t.Fatalf("verify: %v", err)
	}
	if got, err := st.KeyByHash(ctx, "hash-1"); err != nil || !got.ContactVerified {
		t.Fatalf("确认之后应读到已验证：%+v %v", got, err)
	}

	// 最近使用时间写一次，再读回来。
	if err := st.TouchKey(ctx, "key-1"); err != nil {
		t.Fatalf("touch: %v", err)
	}
	keys, err = st.KeysByUser(ctx, user.ID)
	if err != nil || keys[0].LastUsedAt.IsZero() {
		t.Fatalf("最近使用时间应已写入：%+v %v", keys, err)
	}

	// 别的账号撤销不了，本账号撤销之后按摘要查不到，重复撤销按找不到处理。
	if err := st.RevokeKey(ctx, other.ID, "key-1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("别的账号撤销应为 ErrNotFound，得到 %v", err)
	}
	if err := st.RevokeKey(ctx, user.ID, "key-1"); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, err := st.KeyByHash(ctx, "hash-1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("撤销之后应为 ErrNotFound，得到 %v", err)
	}
	if err := st.RevokeKey(ctx, user.ID, "key-1"); !errors.Is(err, auth.ErrNotFound) {
		t.Fatalf("重复撤销应为 ErrNotFound，得到 %v", err)
	}
	keys, err = st.KeysByUser(ctx, user.ID)
	if err != nil || len(keys) != 1 || !keys[0].Revoked {
		t.Fatalf("列表应保留已撤销的一行：%+v %v", keys, err)
	}

	// 删号级联删除密钥。
	if err := st.DeleteUser(ctx, user.ID); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	if keys, err := st.KeysByUser(ctx, user.ID); err != nil || len(keys) != 0 {
		t.Fatalf("删号之后不应留下密钥：%+v %v", keys, err)
	}
}

// TestAPIKeyPruneRevokedKeys 核对已撤销密钥行的清理：只删撤销时间早于截止时间的
// 行，仍然有效的与保留期内撤销的不动（ADR-0063）。
func TestAPIKeyPruneRevokedKeys(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	user := auth.User{ID: "user-prune", PasswordHash: "hash"}
	if err := createAccount(ctx, st, user, "prune@b.cn"); err != nil {
		t.Fatalf("create account: %v", err)
	}
	now := time.Now().UTC()
	keys := []auth.APIKey{
		{ID: "old", UserID: user.ID, Name: "旧", Prefix: "zx_Old00000", CreatedAt: now.Add(-60 * 24 * time.Hour)},
		{ID: "fresh", UserID: user.ID, Name: "新", Prefix: "zx_New00000", CreatedAt: now.Add(-2 * time.Hour)},
		{ID: "active", UserID: user.ID, Name: "在用", Prefix: "zx_Active000", CreatedAt: now},
	}
	hashes := []string{"hash-old", "hash-fresh", "hash-active"}
	for i, key := range keys {
		if err := st.CreateKey(ctx, key, hashes[i], 20); err != nil {
			t.Fatalf("create key %s: %v", key.ID, err)
		}
	}
	// 直接写撤销时间：CreateKey 只写有效密钥，撤销时间由撤销动作写入。
	for id, revokedAt := range map[string]time.Time{
		"old":   now.Add(-40 * 24 * time.Hour),
		"fresh": now.Add(-time.Hour),
	} {
		if _, err := st.pool.Exec(ctx, "UPDATE api_key SET revoked_at = $1 WHERE id = $2", revokedAt, id); err != nil {
			t.Fatalf("revoke %s: %v", id, err)
		}
	}

	removed, err := st.PruneRevokedKeys(ctx, now.Add(-30*24*time.Hour))
	if err != nil || removed != 1 {
		t.Fatalf("应只删除保留期外的 1 行，得到 %d %v", removed, err)
	}
	if keys, err := st.KeysByUser(ctx, user.ID); err != nil || len(keys) != 2 {
		t.Fatalf("清理之后应剩 2 行：%+v %v", keys, err)
	}
	if removed, err := st.PruneRevokedKeys(ctx, now.Add(-48*time.Hour)); err != nil || removed != 0 {
		t.Fatalf("保留期内的撤销行不应删除，得到 %d %v", removed, err)
	}
}

// TestAPIKeyLimitIsAtomic 核对并发签发不会突破上限：同一账号的签发在事务级
// advisory lock 上排队，25 个并发请求里只有 20 把落地，其余返回 ErrKeyLimit
// （ADR-0063）。
func TestAPIKeyLimitIsAtomic(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	user := auth.User{ID: "user-limit", PasswordHash: "hash"}
	if err := createAccount(ctx, st, user, "limit@b.cn"); err != nil {
		t.Fatalf("create account: %v", err)
	}
	const attempts = 25
	var wg sync.WaitGroup
	results := make(chan error, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			key := auth.APIKey{
				ID: fmt.Sprintf("concurrent-%02d", i), UserID: user.ID,
				Name: "并发", Prefix: "zx_Limit0000",
			}
			results <- st.CreateKey(ctx, key, fmt.Sprintf("hash-%02d", i), 20)
		}(i)
	}
	wg.Wait()
	close(results)
	var created, limited int
	for err := range results {
		switch {
		case err == nil:
			created++
		case errors.Is(err, auth.ErrKeyLimit):
			limited++
		default:
			t.Fatalf("并发签发返回意外错误：%v", err)
		}
	}
	if created != 20 || limited != attempts-20 {
		t.Fatalf("并发签发应成功 20 把、拒绝 %d 把，得到 %d 与 %d", attempts-20, created, limited)
	}
	if keys, err := st.KeysByUser(ctx, user.ID); err != nil || len(keys) != 20 {
		t.Fatalf("并发签发之后应正好 20 把：%d %v", len(keys), err)
	}
}
