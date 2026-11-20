package auth

import (
	"context"
	"errors"
	"testing"
	"time"
)

// dangerousHash 是一组参数被故意放大的哈希：内存 1 GiB。校验必须在计算之前
// 拒绝它，否则这个用例会真的去分配那么大的内存。
func dangerousHash() string {
	salt := b64.EncodeToString(make([]byte, 16))
	key := b64.EncodeToString(make([]byte, 32))
	return "$argon2id$v=19$m=1048576,t=2,p=1$" + salt + "$" + key
}

// TestVerifyPasswordRejectsDangerousParams 守住哈希参数的上限与下限：越界的
// 参数返回 errBadHash，而不是继续计算。
func TestVerifyPasswordRejectsDangerousParams(t *testing.T) {
	salt := b64.EncodeToString(make([]byte, 16))
	key := b64.EncodeToString(make([]byte, 32))
	cases := map[string]string{
		"内存过大":  "$argon2id$v=19$m=1048576,t=2,p=1$" + salt + "$" + key,
		"内存为零":  "$argon2id$v=19$m=0,t=2,p=1$" + salt + "$" + key,
		"迭代过多":  "$argon2id$v=19$m=19456,t=100,p=1$" + salt + "$" + key,
		"迭代为零":  "$argon2id$v=19$m=19456,t=0,p=1$" + salt + "$" + key,
		"并行度过大": "$argon2id$v=19$m=19456,t=2,p=32$" + salt + "$" + key,
		"并行度为零": "$argon2id$v=19$m=19456,t=2,p=0$" + salt + "$" + key,
		"盐过短":   "$argon2id$v=19$m=19456,t=2,p=1$" + b64.EncodeToString(make([]byte, 4)) + "$" + key,
		"密钥过短":  "$argon2id$v=19$m=19456,t=2,p=1$" + salt + "$" + b64.EncodeToString(make([]byte, 8)),
		"版本不对":  "$argon2id$v=16$m=19456,t=2,p=1$" + salt + "$" + key,
		"算法不对":  "$scrypt$v=19$m=19456,t=2,p=1$" + salt + "$" + key,
	}
	for name, encoded := range cases {
		t.Run(name, func(t *testing.T) {
			if ok, err := VerifyPassword(encoded, "password1"); err == nil || ok {
				t.Fatalf("应当返回 errBadHash，得到 ok=%v err=%v", ok, err)
			}
		})
	}
}

// TestLoginRejectsDangerousStoredHash 守住“坏哈希不是服务端故障”：库里出现
// 参数越界的哈希时，登录按凭据错误回 401，而不是 500，也不是真的去计算。
func TestLoginRejectsDangerousStoredHash(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	u := User{ID: "u1", PasswordHash: dangerousHash(), CreatedAt: s.now()}
	if err := s.store.CreateAccount(ctx, u, Identity{
		ID: "u1-email", UserID: u.ID, Kind: KindEmail, Identifier: "a@b.cn", CreatedAt: s.now(),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "a@b.cn", "password1", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("库里的参数越界哈希应按凭据错误处理，得到 %v", err)
	}
}

func TestPasswordBudgetCapacity(t *testing.T) {
	for _, tc := range []struct{ mib, want int }{
		{256, 13}, // 256 / 19 向下取整
		{19, 1},
		{18, 1}, // 比一次哈希还小时仍保留 1，否则永远排队
		{0, 1},
	} {
		if got := NewPasswordBudget(tc.mib).Capacity(); got != tc.want {
			t.Errorf("NewPasswordBudget(%d).Capacity() = %d，应为 %d", tc.mib, got, tc.want)
		}
	}
}

func TestPasswordBudgetBlocksWhenFull(t *testing.T) {
	b := NewPasswordBudget(19) // 容量 1
	if err := b.Acquire(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := b.Acquire(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("名额用完时应当等待 ctx，得到 %v", err)
	}
	b.Release()
	if err := b.Acquire(context.Background()); err != nil {
		t.Fatalf("归还之后应当能再取到名额，得到 %v", err)
	}
	b.Release()
}

// TestServiceUsesPasswordBudget 核对注册、登录与重设密码都走同一个预算：
// 容量为 1 时串行执行不会死锁，也不会漏还名额。
func TestServiceUsesPasswordBudget(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestService()
	s.SetPasswordBudget(19)
	if _, err := s.Register(ctx, "a@b.cn", "password1", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "a@b.cn", "password1", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Login(ctx, "a@b.cn", "wrong-password", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("错密码应返回凭据错误，得到 %v", err)
	}
	if _, err := s.Login(ctx, "nobody@b.cn", "password1", ""); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("未知账号应返回凭据错误，得到 %v", err)
	}
}
