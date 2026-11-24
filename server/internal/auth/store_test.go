package auth

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestMemoryResetPasswordIsAtomic 核对内存实现的四步一起生效：摘要对不上时
// 验证码不被用掉，密码、登录方式与会话都不动；对得上时验证码消失、密码换掉、
// 那种登录方式标为已确认、会话清空。
func TestMemoryResetPasswordIsAtomic(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)
	st := NewMemoryStore()
	ident := createEmailAccount(t, st, User{ID: "u1", PasswordHash: "old-hash", CreatedAt: now}, "a@b.cn")
	if err := st.CreateSession(ctx, Session{
		ID: "s1", UserID: "u1", AccessHash: "ah", RefreshHash: "rh",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(time.Hour), CreatedAt: now,
	}, 20, ""); err != nil {
		t.Fatal(err)
	}
	if err := st.PutCode(ctx, Code{
		UserID: "u1", Purpose: PurposeResetPassword,
		Kind: KindEmail, Identifier: "a@b.cn", CodeHash: "good",
		ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateKey(ctx, APIKey{
		ID: "k1", UserID: "u1", Name: "脚本", Prefix: "zx_AbCdEfGh", CreatedAt: now,
	}, "kh1", maxKeysPerUser); err != nil {
		t.Fatal(err)
	}
	reset := PasswordReset{
		UserID: "u1", IdentityID: ident.ID, Purpose: PurposeResetPassword,
		Kind: KindEmail, Identifier: "a@b.cn", ExpectedHash: "good",
		NewPasswordHash: "new-hash", Now: now,
	}

	wrong := reset
	wrong.ExpectedHash = "wrong"
	if err := st.ResetPassword(ctx, wrong); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("摘要对不上时应返回 ErrInvalidCode，得到 %v", err)
	}
	if u, err := st.UserByID(ctx, "u1"); err != nil || u.PasswordHash != "old-hash" {
		t.Fatalf("失败的原子操作不应改密码：%+v %v", u, err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah"); err != nil {
		t.Fatalf("失败的原子操作不应删会话: %v", err)
	}
	if _, err := st.Code(ctx, PurposeResetPassword, KindEmail, "a@b.cn"); err != nil {
		t.Fatalf("失败的原子操作不应吃掉验证码: %v", err)
	}
	if _, err := st.KeyByHash(ctx, "kh1"); err != nil {
		t.Fatalf("失败的原子操作不应撤销密钥: %v", err)
	}

	// 过期验证码同样不算用掉。
	expired := reset
	expired.Now = now.Add(11 * time.Minute)
	if err := st.ResetPassword(ctx, expired); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("过期验证码应返回 ErrInvalidCode，得到 %v", err)
	}

	if err := st.ResetPassword(ctx, reset); err != nil {
		t.Fatalf("正确的摘要应当成功: %v", err)
	}
	if u, err := st.UserByID(ctx, "u1"); err != nil || u.PasswordHash != "new-hash" {
		t.Fatalf("密码应换成新哈希：%+v %v", u, err)
	}
	if got, err := st.Identity(ctx, "u1", ident.ID); err != nil || got.VerifiedAt.IsZero() {
		t.Fatalf("收到验证码的登录方式应标为已确认：%+v %v", got, err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("会话应被清空，得到 %v", err)
	}
	if _, err := st.Code(ctx, PurposeResetPassword, KindEmail, "a@b.cn"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("验证码应被用掉，得到 %v", err)
	}
	if _, err := st.KeyByHash(ctx, "kh1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重设密码之后密钥应全部撤销，得到 %v", err)
	}
	keys, err := st.KeysByUser(ctx, "u1")
	if err != nil || len(keys) != 1 || !keys[0].Revoked {
		t.Fatalf("撤销的密钥应保留在列表里：%+v %v", keys, err)
	}
	// 验证码只能用一次，再用返回 ErrInvalidCode。
	if err := st.ResetPassword(ctx, reset); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("验证码重复使用应返回 ErrInvalidCode，得到 %v", err)
	}
}

// TestMemoryCodesKeyedByIdentity 核对验证码按 (用途, 登录方式, 联系方式) 保存：
// 不同用途互不覆盖，重新发送只覆盖同一用途的那一枚。
func TestMemoryCodesKeyedByIdentity(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)
	st := NewMemoryStore()
	verify := Code{
		Purpose: PurposeVerifyContact, Kind: KindEmail, Identifier: "a@b.cn",
		CodeHash: "v1", ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}
	reset := Code{
		Purpose: PurposeResetPassword, Kind: KindEmail, Identifier: "a@b.cn",
		CodeHash: "r1", ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}
	for _, code := range []Code{verify, reset} {
		if err := st.PutCode(ctx, code); err != nil {
			t.Fatal(err)
		}
	}
	if got, err := st.Code(ctx, PurposeVerifyContact, KindEmail, "a@b.cn"); err != nil || got.CodeHash != "v1" {
		t.Fatalf("确认用途的验证码: %+v %v", got, err)
	}
	reset.CodeHash = "r2"
	if err := st.PutCode(ctx, reset); err != nil {
		t.Fatal(err)
	}
	if got, err := st.Code(ctx, PurposeResetPassword, KindEmail, "a@b.cn"); err != nil || got.CodeHash != "r2" {
		t.Fatalf("重新发送应覆盖同一用途: %+v %v", got, err)
	}
	if got, err := st.Code(ctx, PurposeVerifyContact, KindEmail, "a@b.cn"); err != nil || got.CodeHash != "v1" {
		t.Fatalf("另一个用途不应被覆盖: %+v %v", got, err)
	}
}
