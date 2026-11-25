package pg

import (
	"context"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

// TestKeyUsageJoinsKeys 核对按密钥的对账读取：用量按账号、自然日、用途与密钥
// 分开，api_key 补上名字、前缀、撤销状态与最近使用时间；访问令牌的调用记在空
// 密钥编号的一行；密钥行被清理之后用量仍然保留，名字退化为空（ADR-0076）。
func TestKeyUsageJoinsKeys(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	user := auth.User{ID: "user-key-usage", PasswordHash: "hash"}
	if err := createAccount(ctx, st, user, "key-usage@b.cn"); err != nil {
		t.Fatalf("create account: %v", err)
	}
	key := auth.APIKey{ID: "key-usage-1", UserID: user.ID, Name: "脚本", Prefix: "zx_Usage0000"}
	if err := st.CreateKey(ctx, key, "hash-usage-1", 20); err != nil {
		t.Fatalf("create key: %v", err)
	}
	if err := st.TouchKey(ctx, key.ID); err != nil {
		t.Fatalf("touch key: %v", err)
	}

	const day1, day2, day3 = "2026-11-18", "2026-11-19", "2026-11-20"
	if err := st.Settle(ctx, user.ID, day1, llmproxy.KindChat, key.ID, 0, 120, llmproxy.Usage{Input: 300, Cached: 200}); err != nil {
		t.Fatalf("settle chat: %v", err)
	}
	if err := st.Settle(ctx, user.ID, day1, llmproxy.KindEmbedding, key.ID, 0, 5, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle embedding: %v", err)
	}
	if err := st.Settle(ctx, user.ID, day1, llmproxy.KindChat, "", 0, 40, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle access token: %v", err)
	}
	if err := st.Settle(ctx, user.ID, day2, llmproxy.KindChat, key.ID, 0, 60, llmproxy.Usage{}); err != nil {
		t.Fatalf("settle next day: %v", err)
	}
	// 在途预留也要在视图里看得到，否则对账只看到已结算量，解释不了当天的额度占用。
	if _, err := st.Reserve(ctx, user.ID, day3, llmproxy.KindChat, key.ID, 70); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if err := st.RevokeKey(ctx, user.ID, key.ID); err != nil {
		t.Fatalf("revoke key: %v", err)
	}

	rows, err := st.KeyUsage(ctx, day1, day3)
	if err != nil {
		t.Fatalf("key usage: %v", err)
	}
	type rowKey struct{ day, keyID, kind string }
	got := make(map[rowKey]llmproxy.KeyUsage, len(rows))
	for _, row := range rows {
		if row.UserID != user.ID {
			t.Fatalf("账号不符：%+v", row)
		}
		got[rowKey{row.Day, row.KeyID, string(row.Kind)}] = row
	}
	if len(got) != 5 {
		t.Fatalf("应有 5 行，得到 %d：%+v", len(got), rows)
	}
	chat := got[rowKey{day1, key.ID, "chat"}]
	if chat.Tokens != 120 || chat.InputTokens != 300 || chat.CachedTokens != 200 ||
		chat.Name != "脚本" || chat.Prefix != "zx_Usage0000" || !chat.Revoked || chat.LastUsedAt.IsZero() {
		t.Fatalf("密钥的对话用量不对：%+v", chat)
	}
	if embedding := got[rowKey{day1, key.ID, "embedding"}]; embedding.Tokens != 5 {
		t.Fatalf("嵌入用量不对：%+v", embedding)
	}
	token := got[rowKey{day1, "", "chat"}]
	if token.Tokens != 40 || token.Name != "" || token.Prefix != "" || token.Revoked || !token.LastUsedAt.IsZero() {
		t.Fatalf("访问令牌的用量不对：%+v", token)
	}
	if next := got[rowKey{day2, key.ID, "chat"}]; next.Tokens != 60 {
		t.Fatalf("次日用量不对：%+v", next)
	}
	if reserved := got[rowKey{day3, key.ID, "chat"}]; reserved.Tokens != 0 || reserved.ReservedTokens != 70 {
		t.Fatalf("在途预留不对：%+v", reserved)
	}

	// 区间按自然日过滤：只要 day2 时只剩这一行。
	rows, err = st.KeyUsage(ctx, day2, day2)
	if err != nil || len(rows) != 1 || rows[0].Day != day2 || rows[0].Tokens != 60 {
		t.Fatalf("按区间过滤：%+v %v", rows, err)
	}

	// 密钥行清理之后用量还在：左连接读不到名字，页面按“已清理的密钥”展示。
	if _, err := st.pool.Exec(ctx, `DELETE FROM api_key WHERE id = $1`, key.ID); err != nil {
		t.Fatalf("delete key: %v", err)
	}
	rows, err = st.KeyUsage(ctx, day1, day1)
	if err != nil {
		t.Fatalf("key usage after prune: %v", err)
	}
	for _, row := range rows {
		if row.KeyID == key.ID && row.Name != "" {
			t.Fatalf("清理之后不应再读到名字：%+v", row)
		}
	}
}
