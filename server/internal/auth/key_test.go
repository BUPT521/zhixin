package auth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// newKeyTestService 建一个带内存存储与一个已注册账号的服务，返回服务、账号
// 编号与存储。
func newKeyTestService(t *testing.T) (*Service, string, *MemoryStore) {
	t.Helper()
	store := NewMemoryStore()
	svc := NewService(store, time.Hour, 24*time.Hour)
	tok, err := svc.Register(context.Background(), "tool@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	return svc, tok.UserID, store
}

// TestCreateAPIKeyReturnsUsableSecret 核对签发出来的密钥形状：固定前缀、只留
// 前缀展示，并且能用它换回同一个账号。
func TestCreateAPIKeyReturnsUsableSecret(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	p := Principal{UserID: userID}

	key, secret, err := svc.CreateAPIKey(context.Background(), p, "  脚本  ")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if !strings.HasPrefix(secret, APIKeyPrefix) || len(secret) <= apiKeyPrefixLength {
		t.Fatalf("密钥形状不对：%q", secret)
	}
	if key.Prefix != secret[:apiKeyPrefixLength] {
		t.Fatalf("前缀 %q 与密钥 %q 不一致", key.Prefix, secret)
	}
	if key.Name != "脚本" || key.UserID != userID || key.Revoked {
		t.Fatalf("记录不对：%+v", key)
	}

	got, err := svc.AuthenticateAPIKey(context.Background(), secret)
	if err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if got.UserID != userID || got.KeyID != key.ID || got.SessionID != "" {
		t.Fatalf("调用者不对：%+v", got)
	}
	if got.ContactVerified {
		t.Fatal("邮箱还没有确认，ContactVerified 应为假")
	}
}

// TestAuthenticateAPIKeyReportsContactVerification 核对密钥与访问令牌读同一份
// “至少一种登录方式已验证”。
func TestAuthenticateAPIKeyReportsContactVerification(t *testing.T) {
	svc, userID, store := newKeyTestService(t)
	ctx := context.Background()
	ident, err := store.IdentityByIdentifier(ctx, KindEmail, "tool@b.cn")
	if err != nil {
		t.Fatalf("identity: %v", err)
	}
	if err := store.SetIdentityVerified(ctx, userID, ident.ID, time.Now()); err != nil {
		t.Fatalf("verify: %v", err)
	}
	_, secret, err := svc.CreateAPIKey(ctx, Principal{UserID: userID}, "")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	got, err := svc.AuthenticateAPIKey(ctx, secret)
	if err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if !got.ContactVerified {
		t.Fatal("邮箱已确认，ContactVerified 应为真")
	}
}

// TestRevokeAPIKeyStopsItImmediately 核对撤销：撤销之后鉴权立即失败，列表仍能
// 看到这一行，再撤销一次按找不到处理。
func TestRevokeAPIKeyStopsItImmediately(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	ctx := context.Background()
	p := Principal{UserID: userID}
	key, secret, err := svc.CreateAPIKey(ctx, p, "工具")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := svc.RevokeAPIKey(ctx, p, key.ID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, err := svc.AuthenticateAPIKey(ctx, secret); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("撤销之后应为 ErrInvalidToken，得到 %v", err)
	}
	if err := svc.RevokeAPIKey(ctx, p, key.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("重复撤销应为 ErrNotFound，得到 %v", err)
	}
	keys, err := svc.APIKeys(ctx, p)
	if err != nil || len(keys) != 1 || !keys[0].Revoked {
		t.Fatalf("列表应保留已撤销的一行：%+v %v", keys, err)
	}
}

// TestAPIKeyLimitCountsActiveOnly 核对每个账号的有效密钥上限：达到上限之后
// 拒绝签发，撤销一把之后可以再签。
func TestAPIKeyLimitCountsActiveOnly(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	ctx := context.Background()
	p := Principal{UserID: userID}
	first := APIKey{}
	for i := 0; i < maxKeysPerUser; i++ {
		key, _, err := svc.CreateAPIKey(ctx, p, "k")
		if err != nil {
			t.Fatalf("第 %d 把：%v", i+1, err)
		}
		if i == 0 {
			first = key
		}
	}
	if _, _, err := svc.CreateAPIKey(ctx, p, "k"); !errors.Is(err, ErrKeyLimit) {
		t.Fatalf("达到上限后应为 ErrKeyLimit，得到 %v", err)
	}
	if err := svc.RevokeAPIKey(ctx, p, first.ID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, _, err := svc.CreateAPIKey(ctx, p, "k"); err != nil {
		t.Fatalf("撤销之后应能再签：%v", err)
	}
}

// TestCreateAPIKeyLimitIsAtomic 核对并发签发不会突破上限：多个请求同时签发时，
// 成功的正好是上限那么多把，其余返回 ErrKeyLimit（ADR-0063）。
func TestCreateAPIKeyLimitIsAtomic(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	p := Principal{UserID: userID}
	const attempts = maxKeysPerUser + 5
	var wg sync.WaitGroup
	results := make(chan error, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, err := svc.CreateAPIKey(context.Background(), p, "k")
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	var created, limited int
	for err := range results {
		switch {
		case err == nil:
			created++
		case errors.Is(err, ErrKeyLimit):
			limited++
		default:
			t.Fatalf("并发签发返回意外错误：%v", err)
		}
	}
	if created != maxKeysPerUser || limited != attempts-maxKeysPerUser {
		t.Fatalf("并发签发应成功 %d 把、拒绝 %d 把，得到 %d 与 %d",
			maxKeysPerUser, attempts-maxKeysPerUser, created, limited)
	}
	keys, err := svc.APIKeys(context.Background(), p)
	if err != nil || len(keys) != maxKeysPerUser {
		t.Fatalf("并发签发之后应正好 %d 把：%d %v", maxKeysPerUser, len(keys), err)
	}
}

// TestCreateAPIKeyRejectsLongName 核对名字上限按字符算。
func TestCreateAPIKeyRejectsLongName(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	_, _, err := svc.CreateAPIKey(context.Background(), Principal{UserID: userID},
		strings.Repeat("名", maxKeyNameRunes+1))
	if !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("超长名字应为 ErrInvalidInput，得到 %v", err)
	}
}

// TestAuthenticateAPIKeyRejectsOtherCredentials 核对访问令牌不能当密钥用，未知
// 摘要按无效处理。
func TestAuthenticateAPIKeyRejectsOtherCredentials(t *testing.T) {
	svc, _, _ := newKeyTestService(t)
	ctx := context.Background()
	if _, err := svc.AuthenticateAPIKey(ctx, "opaque-access-token"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("非密钥前缀应为 ErrInvalidToken，得到 %v", err)
	}
	if _, err := svc.AuthenticateAPIKey(ctx, APIKeyPrefix+"not-a-real-key"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("未知密钥应为 ErrInvalidToken，得到 %v", err)
	}
}

// TestTouchAPIKeyRecordsUses 核对最近使用时间会被记下，列表里读得到。
func TestTouchAPIKeyRecordsUses(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	ctx := context.Background()
	p := Principal{UserID: userID}
	key, secret, err := svc.CreateAPIKey(ctx, p, "")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := svc.AuthenticateAPIKey(ctx, secret); err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	keys, err := svc.APIKeys(ctx, p)
	if err != nil || len(keys) != 1 || keys[0].ID != key.ID {
		t.Fatalf("列表不对：%+v %v", keys, err)
	}
	if keys[0].LastUsedAt.IsZero() {
		t.Fatal("用过一次之后应有最近使用时间")
	}
}

// TestDeleteUserRemovesAPIKeys 核对删号时密钥随外键级联消失。
func TestDeleteUserRemovesAPIKeys(t *testing.T) {
	svc, userID, store := newKeyTestService(t)
	ctx := context.Background()
	_, secret, err := svc.CreateAPIKey(ctx, Principal{UserID: userID}, "")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := store.DeleteUser(ctx, userID); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	if _, err := svc.AuthenticateAPIKey(ctx, secret); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("删号之后密钥应失效，得到 %v", err)
	}
}

// TestLooksLikeAPIKeyChecksShape 守住类型区分与格式校验：以 zx_ 开头但长度是访问
// 令牌的 43 个字符时不能当成密钥，长度对而校验码不对的串同样在查库之前被拒掉。
func TestLooksLikeAPIKeyChecksShape(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	_, secret, err := svc.CreateAPIKey(context.Background(), Principal{UserID: userID}, "")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if !LooksLikeAPIKey(secret) {
		t.Fatalf("签发的密钥应被认出来：%q", secret)
	}
	if len(secret) != apiKeyLength {
		t.Fatalf("密钥长度应为 %d，得到 %d", apiKeyLength, len(secret))
	}
	if LooksLikeAPIKey(APIKeyPrefix + strings.Repeat("a", 40)) {
		t.Fatal("43 个字符的访问令牌不应被当成密钥")
	}
	tampered := secret[:len(secret)-1] + "A"
	if tampered == secret {
		tampered = secret[:len(secret)-1] + "B"
	}
	if LooksLikeAPIKey(tampered) {
		t.Fatalf("校验码不对的串不应被当成密钥：%q", tampered)
	}
}

// countingTouchStore 在内存存储外面数 TouchKey 的调用次数，用于核对进程内节流。
type countingTouchStore struct {
	*MemoryStore
	touches atomic.Int64
}

func (s *countingTouchStore) TouchKey(ctx context.Context, id string) error {
	s.touches.Add(1)
	return s.MemoryStore.TouchKey(ctx, id)
}

// TestAuthenticateAPIKeyThrottlesTouch 核对最近使用时间在进程内按十分钟节流：
// 十分钟内重复使用同一把密钥只尝试写一次数据库，超过之后再写一次（ADR-0063）。
func TestAuthenticateAPIKeyThrottlesTouch(t *testing.T) {
	c := &clock{t: time.Date(2026, 11, 14, 9, 0, 0, 0, time.UTC)}
	store := &countingTouchStore{MemoryStore: NewMemoryStore()}
	svc := NewService(store, time.Hour, 24*time.Hour)
	svc.now = c.now
	ctx := context.Background()
	tok, err := svc.Register(ctx, "touch@b.cn", "password1", "")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	_, secret, err := svc.CreateAPIKey(ctx, Principal{UserID: tok.UserID}, "脚本")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	for i := 0; i < 3; i++ {
		if _, err := svc.AuthenticateAPIKey(ctx, secret); err != nil {
			t.Fatalf("authenticate %d: %v", i+1, err)
		}
	}
	if got := store.touches.Load(); got != 1 {
		t.Fatalf("十分钟内应只尝试写一次最近使用时间，得到 %d", got)
	}
	c.t = c.t.Add(keyTouchInterval + time.Second)
	if _, err := svc.AuthenticateAPIKey(ctx, secret); err != nil {
		t.Fatalf("authenticate after interval: %v", err)
	}
	if got := store.touches.Load(); got != 2 {
		t.Fatalf("超过十分钟应按同一粒度再写一次，得到 %d", got)
	}
}

// TestRevokeAllAPIKeys 核对撤销全部：每一把都立即失效，返回的条数只算仍然有效
// 的那些，再撤一次得到 0。
func TestRevokeAllAPIKeys(t *testing.T) {
	svc, userID, _ := newKeyTestService(t)
	ctx := context.Background()
	p := Principal{UserID: userID}
	_, first, err := svc.CreateAPIKey(ctx, p, "甲")
	if err != nil {
		t.Fatalf("create first: %v", err)
	}
	_, second, err := svc.CreateAPIKey(ctx, p, "乙")
	if err != nil {
		t.Fatalf("create second: %v", err)
	}
	revoked, err := svc.RevokeAllAPIKeys(ctx, p)
	if err != nil || revoked != 2 {
		t.Fatalf("应撤销 2 把，得到 %d %v", revoked, err)
	}
	for _, secret := range []string{first, second} {
		if _, err := svc.AuthenticateAPIKey(ctx, secret); !errors.Is(err, ErrInvalidToken) {
			t.Fatalf("撤销全部之后应失效，得到 %v", err)
		}
	}
	if revoked, err := svc.RevokeAllAPIKeys(ctx, p); err != nil || revoked != 0 {
		t.Fatalf("再撤一次应撤销 0 把，得到 %d %v", revoked, err)
	}
}

// TestPruneLoopDeletesStaleRevokedKeys 核对每日清理删除撤销超过保留期的密钥行：
// 反复签发再撤销不会让表和列表无限变长，保留期内的撤销记录仍能回看，仍然有效的
// 密钥不受影响（ADR-0063）。
func TestPruneLoopDeletesStaleRevokedKeys(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s, c := newTestService()
	st := s.store.(*MemoryStore)
	user := createEmailAccount(t, st, User{ID: "u-key", PasswordHash: "h", CreatedAt: c.t}, "keys@b.cn")
	keys := []APIKey{
		{ID: "old", UserID: user.ID, Name: "旧", Prefix: "zx_Old00000", Revoked: true,
			RevokedAt: c.t.Add(-revokedKeyKeep - time.Hour), CreatedAt: c.t.Add(-60 * 24 * time.Hour)},
		{ID: "fresh", UserID: user.ID, Name: "新", Prefix: "zx_New00000", Revoked: true,
			RevokedAt: c.t.Add(-time.Hour), CreatedAt: c.t.Add(-2 * time.Hour)},
		{ID: "active", UserID: user.ID, Name: "在用", Prefix: "zx_Active000", CreatedAt: c.t},
	}
	for _, key := range keys {
		if err := st.CreateKey(ctx, key, "hash-"+key.ID, maxKeysPerUser); err != nil {
			t.Fatalf("create key %s: %v", key.ID, err)
		}
	}

	done := make(chan struct{})
	go func() {
		s.PruneLoop(ctx, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
		close(done)
	}()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if listed, err := s.APIKeys(ctx, Principal{UserID: user.ID}); err == nil && len(listed) == 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("ctx 结束之后 PruneLoop 应当退出")
	}

	listed, err := s.APIKeys(ctx, Principal{UserID: user.ID})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(listed) != 2 {
		t.Fatalf("保留期外的撤销行应被删除，得到 %+v", listed)
	}
	for _, key := range listed {
		if key.ID == "old" {
			t.Fatal("撤销超过保留期的密钥行应当已被删除")
		}
	}
}
