package pg

import (
	"context"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
)

// createAccount 在测试库里写入一个账号与它的一条邮箱登录方式。生产代码走
// Store.CreateAccount，测试只需要“有一个带邮箱的账号”，邮箱的值不参与被测行为。
// 账号与登录方式的创建时间由表上的默认值给出。
func createAccount(ctx context.Context, st *Store, u auth.User, email string) error {
	return st.CreateAccount(ctx, u, auth.Identity{
		ID:         u.ID + "-email",
		UserID:     u.ID,
		Kind:       auth.KindEmail,
		Identifier: email,
	})
}

// TestListAccountsAndQuotaOverride 核对管理后台用的两条 PostgreSQL 路径：账号
// 检索按邮箱片段与编号命中、分页不重复，额度覆盖写入之后 DailyLimit 立即读到，
// 清除之后回到默认。查询里的 position 与 lower 让 % 与 _ 只当普通字符。
func TestListAccountsAndQuotaOverride(t *testing.T) {
	st := newTestStore(t)
	ctx := context.Background()
	for _, account := range []struct {
		id    string
		email string
	}{
		{"user-a", "alice@example.test"},
		{"user-b", "bob+tag@example.test"},
		{"user-c", "carol_100%@example.test"},
	} {
		if err := createAccount(ctx, st, auth.User{ID: account.id, PasswordHash: "hash"}, account.email); err != nil {
			t.Fatalf("create %s: %v", account.id, err)
		}
	}

	for _, tc := range []struct {
		query string
		want  []string
	}{
		{"", []string{"user-a", "user-b", "user-c"}},
		{"ALICE@", []string{"user-a"}},
		{"user-b", []string{"user-b"}},
		{"%", []string{"user-c"}},
		{"_100%", []string{"user-c"}},
		{"nobody", nil},
	} {
		records, total, err := st.ListAccounts(ctx, tc.query, 100, 0)
		if err != nil {
			t.Fatalf("list %q: %v", tc.query, err)
		}
		if total != len(tc.want) || len(records) != len(tc.want) {
			t.Fatalf("list %q: total=%d records=%d want=%v", tc.query, total, len(records), tc.want)
		}
		got := map[string]bool{}
		for _, record := range records {
			got[record.User.ID] = true
			if len(record.Identities) != 1 || record.Identities[0].UserID != record.User.ID {
				t.Fatalf("list %q: identities = %+v", tc.query, record.Identities)
			}
		}
		for _, id := range tc.want {
			if !got[id] {
				t.Fatalf("list %q missing %s: %+v", tc.query, id, records)
			}
		}
	}
	page, total, err := st.ListAccounts(ctx, "", 2, 0)
	if err != nil || total != 3 || len(page) != 2 {
		t.Fatalf("first page: total=%d len=%d err=%v", total, len(page), err)
	}
	second, _, err := st.ListAccounts(ctx, "", 2, 2)
	if err != nil || len(second) != 1 || second[0].User.ID == page[0].User.ID || second[0].User.ID == page[1].User.ID {
		t.Fatalf("second page: %+v err=%v", second, err)
	}

	daily := int64(5000)
	if err := st.SetQuotaOverride(ctx, "user-a", &daily, "内测"); err != nil {
		t.Fatalf("set quota: %v", err)
	}
	if limit, ok, err := st.DailyLimit(ctx, "user-a"); err != nil || !ok || limit != 5000 {
		t.Fatalf("shared limit: %d %v %v", limit, ok, err)
	}
	overrides, err := st.QuotaOverrides(ctx, []string{"user-a", "user-b"})
	if err != nil {
		t.Fatalf("overrides: %v", err)
	}
	a, ok := overrides["user-a"]
	if !ok || a.DailyTokens == nil || *a.DailyTokens != 5000 ||
		a.Note != "内测" || a.UpdatedAt.IsZero() {
		t.Fatalf("override a: %+v", a)
	}
	if _, ok := overrides["user-b"]; ok {
		t.Fatalf("user-b should have no override: %+v", overrides)
	}

	if err := st.SetQuotaOverride(ctx, "user-a", nil, ""); err != nil {
		t.Fatalf("clear by empty set: %v", err)
	}
	if _, ok, err := st.DailyLimit(ctx, "user-a"); err != nil || ok {
		t.Fatalf("empty set should remove the override: %v %v", ok, err)
	}
	if err := st.ClearQuotaOverride(ctx, "user-a"); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if _, ok, err := st.DailyLimit(ctx, "user-a"); err != nil || ok {
		t.Fatalf("clear should remove the override: %v %v", ok, err)
	}
}
