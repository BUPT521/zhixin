package auth

import "context"

// passwordMemoryMiB 是一次 Argon2 哈希占用的内存，与 password.go 里的参数一致。
// 预算按它换算并发数，改哈希参数时两处要一起看。
const passwordMemoryMiB = 19

// PasswordBudget 限制同时进行的 Argon2 计算数。
//
// 每次哈希固定占用约 19 MiB，若不加限制，一批并发登录就能把实例的内存占满，
// 注册、登录、重设密码与删号都会被拖垮。容量由内存预算除以单次占用算出，至少
// 为 1，否则预算配得比单次占用还小时所有密码操作都会永远排队。
type PasswordBudget struct {
	slots chan struct{}
}

// NewPasswordBudget 按内存预算（MiB）建预算器。
func NewPasswordBudget(mib int) *PasswordBudget {
	n := mib / passwordMemoryMiB
	if n < 1 {
		n = 1
	}
	return &PasswordBudget{slots: make(chan struct{}, n)}
}

// Capacity 报告并发上限，供装配检查与测试核对。
func (b *PasswordBudget) Capacity() int { return cap(b.slots) }

// Acquire 取一个名额；ctx 先结束时返回 ctx.Err()，调用方此时不应再计算哈希。
// 预算器为零值时直接放行，未配置预算的装配与单元测试因此不用额外分支。
func (b *PasswordBudget) Acquire(ctx context.Context) error {
	if b == nil {
		return nil
	}
	select {
	case b.slots <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Release 归还名额，只能与成功的 Acquire 配对。
func (b *PasswordBudget) Release() {
	if b == nil {
		return
	}
	<-b.slots
}
