package pg

import (
	"context"

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
