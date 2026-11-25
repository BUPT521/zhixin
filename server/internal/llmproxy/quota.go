package llmproxy

import (
	"context"
	"errors"
	"sync"
)

// Quota tracks tokens used per account, model kind, and local day. The day key is a
// YYYY-MM-DD string in the configured time zone (ZHIXIN_TIMEZONE).
//
// 托管额度先预留再结算：转发前按请求体大小估算一个 token 上限并 Reserve，转发
// 结束后按提供方返回的 usage Settle。预留让同时发起的请求在同一个额度上互相
// 看得见，结算再按实际用量多退少补。
//
// DailyLimit 读取按账号调整过的每日额度；没有覆盖行时返回 ok=false，由代理用
// 聊天与嵌入各自的默认额度。管理员在 llm_quota 表里调整，见 server/README。
type Quota interface {
	Used(ctx context.Context, userID, day string, kind Kind) (int64, error)
	Add(ctx context.Context, userID, day string, kind Kind, tokens int64) error
	DailyLimit(ctx context.Context, userID string, kind Kind) (int64, bool, error)
	// Reserve 原子预留 want 个计费 token，成功时返回 want。keyID 是这次调用用的
	// 模型代理密钥编号，用访问令牌调用时为空字符串；用量按它分开记，额度仍按账号
	// 合计。账号额度或实例预算不足以覆盖 want 时返回 *QuotaExceededError，原因写
	// 在 Reason 里，不再按剩余量截断：调用方据此回 429 并说明是哪种额度用完。
	Reserve(ctx context.Context, userID, day string, kind Kind, keyID string, want int64) (reserved int64, err error)
	// Settle 把这次预留转成实际用量：reserved 从在途预留里扣掉，actual 记进已
	// 结算用量。keyID 必须与这次预留相同，结算才会落到同一行。reserved 与 actual
	// 都是计费 token（见 Usage.Billed）；usage 是来源报告的原始拆分，只为统计缓存
	// 命中，不参与扣减。实例账本只调整免费额度内的那一段，超出部分由积分承担
	// （ADR-0070）。
	Settle(ctx context.Context, userID, day string, kind Kind, keyID string, reserved, actual int64, usage Usage) error
	// InstanceUsed 返回实例当天的账本用量，用于展示与判断实例预算。账本与账号
	// 无关，删号不会减少它。
	InstanceUsed(ctx context.Context, day string) (int64, error)
	// Points 返回账号的积分视图：当天已经核销成功的积分与余额副本里还可以使用的
	// 积分。没有开通收款时 Known 为 false，接口据此不回这两个数。
	Points(ctx context.Context, userID, day string) (Points, error)
}

// Points 是账号的积分视图，用于账号页展示。Charged 是当天已经落库成功的核销，
// Remaining 是余额副本里可用的积分。
type Points struct {
	Charged   int64
	Remaining int64
	Known     bool
}

// ErrQuotaExceeded 表示账号当日额度或实例总预算不足；代理据此回 429
// quota_exceeded，调用方用 errors.Is 判断。具体原因见 QuotaExceededError。
var ErrQuotaExceeded = errors.New("llmproxy: 托管额度不足")

// QuotaReason 说明这次 429 用的是哪一种额度。客户端按它决定是引导购买积分，还是
// 只说稍后再试（ADR-0071）。
type QuotaReason string

const (
	// QuotaReasonAccount 表示账号当天的免费额度用完，也没有可用的积分。
	QuotaReasonAccount QuotaReason = "account"
	// QuotaReasonPoints 表示免费额度用完，可用积分不够这一次预留。
	QuotaReasonPoints QuotaReason = "points"
	// QuotaReasonInstance 表示实例当天的预算用完，与账号自己的额度无关。
	QuotaReasonInstance QuotaReason = "instance"
)

// QuotaExceededError 是预留被拒的原因。errors.Is(err, ErrQuotaExceeded) 对每一类
// 原因都成立，errors.As 取到它就能读出原因。
type QuotaExceededError struct{ Reason QuotaReason }

func (e *QuotaExceededError) Error() string {
	return "llmproxy: 托管额度不足（" + string(e.Reason) + "）"
}

// Is 让 errors.Is(err, ErrQuotaExceeded) 对每一类原因都成立。
func (e *QuotaExceededError) Is(target error) bool { return target == ErrQuotaExceeded }

// quotaLimits 是配额实现接收上限的约定：默认每日额度与实例预算只有配置一处
// 来源，NewHandler 装配时注入给实现，Reserve 用它做原子比较。内存与 PostgreSQL
// 两种实现都实现了这个方法。
type quotaLimits interface {
	SetQuotaLimits(dailyTokens, embeddingDailyTokens, instanceDailyTokens int64)
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu sync.Mutex
	// used 的键是账号、自然日、用途与模型代理密钥编号；密钥编号为空表示访问令牌。
	// 额度判定按账号合计，记账按密钥分开，与 PostgreSQL 实现同一口径（ADR-0063）。
	used map[[4]string]int64
	// reserved 记还没有结算的在途预留，与 used 同键；额度判定看两者之和，展示与
	// 核销只看 used，口径与 llm_usage 的两列一致（ADR-0071）。
	reserved map[[4]string]int64
	// split 记最近一次结算的原始用量，与 used 同键；只用于核对缓存命中统计。
	split  map[[4]string]Usage
	limits map[[2]string]int64
	// instance 是实例当天的账本，按自然日记 token 数；它与 used 分开保存，删号
	// 只清 used，已经占用的实例预算因此不会重新腾出来（ADR-0036）。
	instance map[string]int64

	// dailyTokens 与 instanceTokens 是配置里的默认额度与实例预算，由 NewHandler
	// 装配时注入；小于等于 0 表示不限。
	dailyTokens          int64
	embeddingDailyTokens int64
	instanceTokens       int64
}

func NewMemoryQuota() *MemoryQuota {
	return &MemoryQuota{
		used:     map[[4]string]int64{},
		reserved: map[[4]string]int64{},
		split:    map[[4]string]Usage{},
		limits:   map[[2]string]int64{},
		instance: map[string]int64{},
	}
}

// SetQuotaLimits 注入配置里的默认每日额度与实例预算；由 NewHandler 在装配时调用。
func (m *MemoryQuota) SetQuotaLimits(dailyTokens, embeddingDailyTokens, instanceDailyTokens int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dailyTokens = dailyTokens
	m.embeddingDailyTokens = embeddingDailyTokens
	m.instanceTokens = instanceDailyTokens
}

// Used 返回已经结算的计费 token 数，不包含在途预留：展示与核销用这一份。
func (m *MemoryQuota) Used(_ context.Context, userID, day string, kind Kind) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.settledByAccountLocked(userID, day, kind), nil
}

// settledByAccountLocked 汇总账号当天某类模型已经结算的用量。调用方必须持有 m.mu。
func (m *MemoryQuota) settledByAccountLocked(userID, day string, kind Kind) int64 {
	var total int64
	for key, tokens := range m.used {
		if key[0] == userID && key[1] == day && key[2] == string(kind) {
			total += tokens
		}
	}
	return total
}

// occupiedByAccountLocked 汇总已结算与在途预留，额度判定按这个合计。
func (m *MemoryQuota) occupiedByAccountLocked(userID, day string, kind Kind) int64 {
	total := m.settledByAccountLocked(userID, day, kind)
	for key, tokens := range m.reserved {
		if key[0] == userID && key[1] == day && key[2] == string(kind) {
			total += tokens
		}
	}
	return total
}

func (m *MemoryQuota) Add(_ context.Context, userID, day string, kind Kind, tokens int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	// Add 只用于按账号累加已结算用量，没有密钥可归；与访问令牌调用记在同一行。
	m.used[[4]string{userID, day, string(kind), ""}] += tokens
	return nil
}

// Reserve 在锁里完成比较与扣减，同一账号或同一天的并发请求不会各自读到旧值。
// 比较用账号合计，记在这一次调用的密钥那一行；不足以覆盖 want 时返回带原因的
// 错误，不再截断（ADR-0071）。
func (m *MemoryQuota) Reserve(_ context.Context, userID, day string, kind Kind, keyID string, want int64) (int64, error) {
	if want <= 0 {
		return 0, &QuotaExceededError{Reason: QuotaReasonAccount}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	key := [4]string{userID, day, string(kind), keyID}
	limit, limited := m.accountLimitLocked(userID, kind)
	free := int64(0)
	if limited {
		free = max(0, limit-m.occupiedByAccountLocked(userID, day, kind))
	}
	if limited && want > free {
		return 0, &QuotaExceededError{Reason: QuotaReasonAccount}
	}
	// 实例账本只累计免费额度内的部分：超出免费额度、由积分承担的量已经有收入
	// 覆盖，不再占用给免费额度兜底的实例预算（ADR-0070）。
	instance := instancePortion(want, free, limited)
	if m.instanceTokens > 0 && instance > max(0, m.instanceTokens-m.instance[day]) {
		return 0, &QuotaExceededError{Reason: QuotaReasonInstance}
	}
	m.reserved[key] += want
	m.instance[day] += instance
	return want, nil
}

func (m *MemoryQuota) Settle(_ context.Context, userID, day string, kind Kind, keyID string, reserved, actual int64, usage Usage) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	// 缓存命中的拆分与 PostgreSQL 的 llm_usage 一样按密钥分行记，内存实现里
	// 单独存一份，供本地联调与测试核对；额度判定只看计费后的总量。
	m.split[[4]string{userID, day, string(kind), keyID}] = usage
	if actual == 0 && reserved == 0 && usage.Total() == 0 {
		return nil
	}
	key := [4]string{userID, day, string(kind), keyID}
	// 实例账本只加减免费额度内的部分。结算前的账号合计含这次预留，先减掉它
	// 才知道这次请求开始时已经用掉多少免费额度。
	instance := actual - reserved
	if limit, limited := m.accountLimitLocked(userID, kind); limited {
		before := max(0, m.occupiedByAccountLocked(userID, day, kind)-reserved)
		free := max(0, limit-before)
		instance = min(actual, free) - min(reserved, free)
	}
	m.reserved[key] = max(0, m.reserved[key]-reserved)
	settled := m.used[key] + actual
	m.used[key] = max(0, settled)
	m.instance[day] = max(0, m.instance[day]+instance)
	return nil
}

// Split 返回账号当天某类模型最近一次结算记录下来的原始用量，只为核对缓存命中
// 的统计口径；生产走 PostgreSQL，那里的拆分按天累加，这里只留最近一条。
func (m *MemoryQuota) Split(userID, day string, kind Kind) Usage {
	m.mu.Lock()
	defer m.mu.Unlock()
	v := m.split[[4]string{userID, day, string(kind), ""}]
	return v
}

func (m *MemoryQuota) InstanceUsed(_ context.Context, day string) (int64, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.instance[day], nil
}

// Points 在内存实现里没有积分：本地联调不配即刻收，返回未知，接口不回这两个数。
func (m *MemoryQuota) Points(context.Context, string, string) (Points, error) {
	return Points{}, nil
}

// instancePortion 返回一次预留里应当记进实例账本的计费 token 数：只有免费额度
// 内的部分占用实例预算，超出免费额度、由积分承担的量不占（ADR-0070）。
func instancePortion(reserved, freeRemaining int64, limited bool) int64 {
	if !limited {
		return reserved
	}
	return min(reserved, freeRemaining)
}

// accountLimitLocked 返回账号当天的额度：覆盖值优先，其次配置的默认值；都没有
// 时 ok 为 false，表示不限额度。调用方必须持有 m.mu。
func (m *MemoryQuota) accountLimitLocked(userID string, kind Kind) (int64, bool) {
	if limit, ok := m.limits[[2]string{userID, string(kind)}]; ok {
		return limit, true
	}
	limit := m.dailyTokens
	if kind == KindEmbedding {
		limit = m.embeddingDailyTokens
	}
	return limit, limit > 0
}

// SetDailyLimit 调整一个账号的每日额度，供本地联调与测试使用；生产上改
// llm_quota 表。
func (m *MemoryQuota) SetDailyLimit(userID string, tokens int64) {
	m.SetKindLimit(userID, KindChat, tokens)
}

// SetKindLimit 调整一个账号某类模型的每日额度。
func (m *MemoryQuota) SetKindLimit(userID string, kind Kind, tokens int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.limits[[2]string{userID, string(kind)}] = tokens
}

func (m *MemoryQuota) DailyLimit(_ context.Context, userID string, kind Kind) (int64, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	limit, ok := m.limits[[2]string{userID, string(kind)}]
	return limit, ok, nil
}

// DeleteUser 清掉账号自己的用量与额度覆盖值。实例账本不在这里清：它记录的是
// 提供方已经计费的用量，删号不会让那笔费用消失（ADR-0036）。
func (m *MemoryQuota) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k := range m.used {
		if k[0] == userID {
			delete(m.used, k)
		}
	}
	for k := range m.reserved {
		if k[0] == userID {
			delete(m.reserved, k)
		}
	}
	delete(m.limits, [2]string{userID, string(KindChat)})
	delete(m.limits, [2]string{userID, string(KindEmbedding)})
	return nil
}
