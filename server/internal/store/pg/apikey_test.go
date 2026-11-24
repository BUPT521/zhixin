package pg

import (
	"context"
	"errors"
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
	if err := st.CreateKey(ctx, key, "hash-1"); err != nil {
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
