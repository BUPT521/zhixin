package auth

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestMemoryResetPasswordIsAtomic 核对内存实现的三步一起生效：摘要对不上时
// 验证码不被用掉，密码与会话都不动；对得上时验证码消失、密码换掉、会话清空。
func TestMemoryResetPasswordIsAtomic(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)
	st := NewMemoryStore()
	if err := st.CreateUser(ctx, User{ID: "u1", Email: "a@b.cn", PasswordHash: "old-hash", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateSession(ctx, Session{
		ID: "s1", UserID: "u1", AccessHash: "ah", RefreshHash: "rh",
		AccessExpires: now.Add(time.Hour), RefreshExpires: now.Add(time.Hour), CreatedAt: now,
	}, 20); err != nil {
		t.Fatal(err)
	}
	if err := st.PutCode(ctx, Code{
		UserID: "u1", Purpose: PurposeResetPassword, CodeHash: "good",
		ExpiresAt: now.Add(10 * time.Minute), CreatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}

	if err := st.ResetPassword(ctx, "u1", PurposeResetPassword, "wrong", "new-hash", now); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("摘要对不上时应返回 ErrInvalidCode，得到 %v", err)
	}
	if u, err := st.UserByID(ctx, "u1"); err != nil || u.PasswordHash != "old-hash" {
		t.Fatalf("失败的原子操作不应改密码：%+v %v", u, err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah"); err != nil {
		t.Fatalf("失败的原子操作不应删会话: %v", err)
	}
	if _, err := st.Code(ctx, "u1", PurposeResetPassword); err != nil {
		t.Fatalf("失败的原子操作不应吃掉验证码: %v", err)
	}

	// 过期验证码同样不算用掉。
	if err := st.ResetPassword(ctx, "u1", PurposeResetPassword, "good", "new-hash", now.Add(11*time.Minute)); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("过期验证码应返回 ErrInvalidCode，得到 %v", err)
	}

	if err := st.ResetPassword(ctx, "u1", PurposeResetPassword, "good", "new-hash", now); err != nil {
		t.Fatalf("正确的摘要应当成功: %v", err)
	}
	if u, err := st.UserByID(ctx, "u1"); err != nil || u.PasswordHash != "new-hash" {
		t.Fatalf("密码应换成新哈希：%+v %v", u, err)
	}
	if _, err := st.SessionByAccessHash(ctx, "ah"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("会话应被清空，得到 %v", err)
	}
	if _, err := st.Code(ctx, "u1", PurposeResetPassword); !errors.Is(err, ErrNotFound) {
		t.Fatalf("验证码应被用掉，得到 %v", err)
	}
	// 验证码只能用一次，再用返回 ErrInvalidCode。
	if err := st.ResetPassword(ctx, "u1", PurposeResetPassword, "good", "another-hash", now); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("验证码重复使用应返回 ErrInvalidCode，得到 %v", err)
	}
}
