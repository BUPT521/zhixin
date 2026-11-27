package llmproxy

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
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
	// （ADR-0070）。失败按 0 结算时 actual 是 0，token 两列都不变，所以另外传一次
	// 尝试与它失败与否，让后台看得见失败的调用（ADR-0083）。
	Settle(ctx context.Context, userID, day string, kind Kind, keyID string, reserved, actual int64, usage Usage, attempt SettleAttempt) error
	// InstanceUsed 返回实例当天的账本用量，用于展示与判断实例预算。账本与账号
	// 无关，删号不会减少它。
	InstanceUsed(ctx context.Context, day string) (int64, error)
	// Points 返回账号当天核销成功的积分和余额中尚未占用的整积分。两个数各自有一个“已知”
	// 标记：没有开通收款时都给不出，余额副本还没建好或账号还没有副本时只给已核销
	// 积分，接口据此分别决定哪个字段回 null，见 ADR-0073。
	Points(ctx context.Context, userID, day string) (Points, error)
	// PointCharges 返回账号最近的核销流水，新到旧，供管理后台查看；没有开通收款时
	// 返回空。只读，不改变流水状态。
	PointCharges(ctx context.Context, userID string, limit int) ([]PointCharge, error)
	// RefreshPoints 同步查询一次即刻收的余额并覆盖本地副本，供管理后台的“刷新余额”
	// 使用；没有开通收款时返回 false，表示这次没有查询。
	RefreshPoints(ctx context.Context, userID string) (bool, error)

	// QuotaOverrides 批量读取管理后台用到的额度覆盖行。它只返回有覆盖的账号，
	// 没有出现说明这一类额度走实例默认值；一次读回一页账号，避免逐行查询。
	QuotaOverrides(ctx context.Context, userIDs []string) (map[string]QuotaOverride, error)
	// SetQuotaOverride 整体替换一个账号的额度覆盖值；某一项为 nil 时回到实例
	// 默认值，两项都为 nil 且备注为空时删除覆盖行。下一次模型请求生效。
	SetQuotaOverride(ctx context.Context, userID string, daily, embedding *int64, note string) error
	// ClearQuotaOverride 删除覆盖行，这个账号回到实例默认额度。
	ClearQuotaOverride(ctx context.Context, userID string) error
}

// QuotaOverride 是管理后台看到的一个账号额度覆盖行。指针为空表示这一项没有
// 单独调整过，实际放行时用配置的默认额度；UpdatedAt 为零值表示没有这一行。
type QuotaOverride struct {
	DailyTokens          *int64
	EmbeddingDailyTokens *int64
	Note                 string
	UpdatedAt            time.Time
}

// SettleAttempt 是这次结算对应的尝试与它的结果。失败的尝试按 ADR-0070 记 0，
// tokens 与 reserved_tokens 都不留痕迹，后台因此要靠这两个计数才看得见一直在
// 失败的密钥（ADR-0083）。两者只进 llm_usage 的两列统计，不参与额度判定、预留
// 与核销，也不改变已有的 token 数字。
type SettleAttempt struct {
	// Attempts 是这一次结算对应的尝试次数，通常是 1。
	Attempts int64
	// Failures 是其中失败、按 0 结算的次数，通常是 0 或 1。
	Failures int64
}

// attemptOf 返回一次尝试、失败的记一次失败。
func attemptOf(failed bool) SettleAttempt {
	out := SettleAttempt{Attempts: 1}
	if failed {
		out.Failures = 1
	}
	return out
}

// Points 是账号的积分视图，用于账号页与管理后台展示。Charged 是当天已经落库成功
// 的核销，Remaining 是可用积分，与额度放行用同一个口径。ChargedKnown 为真表示收款
// 已经开通、Charged 有效；RemainingKnown 为真表示余额副本可用、Remaining 有效。
// SyncedAt 是这份副本对应的快照时刻，零值表示没有副本。
type Points struct {
	Charged        int64
	Remaining      int64
	ChargedKnown   bool
	RemainingKnown bool
	SyncedAt       time.Time
}

// PointCharge 是一笔积分核销流水在管理后台的视图。ID 同时是提交给即刻收的
// out_request_no；BilledTokens 是这次申请对应的计费 token 数。它只读，后台不提供
// 撤销或补扣。
type PointCharge struct {
	ID           string
	Day          time.Time
	Points       int64
	BilledTokens int64
	Status       string
	CreatedAt    time.Time
	UpdatedAt    time.Time
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
	// QuotaReasonSyncing 表示余额副本缺失或过期、服务端刚刚排了一次查询，这一轮
	// 还不能确定积分够不够。客户端只提示稍后重试，不引导购买，见 ADR-0073。
	QuotaReasonSyncing QuotaReason = "syncing"
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

// memoryUsageKey matches the dimensions of an llm_usage row.
type memoryUsageKey struct {
	userID, day string
	kind        Kind
	keyID       string
}

type memoryUsageRow struct {
	KeyUsageCounts
	last Usage
}

// MemoryQuota is a Quota kept in process memory.
type MemoryQuota struct {
	mu         sync.Mutex
	usage      map[memoryUsageKey]memoryUsageRow
	keysByUser func(context.Context, string) ([]auth.APIKey, error)
	// limits 是管理后台调整过的额度覆盖值；quotaNotes 与 quotaUpdated 跟着覆盖行
	// 一起保存，供后台列表显示备注与保存时间。
	limits       map[[2]string]int64
	quotaNotes   map[string]string
	quotaUpdated map[string]time.Time
	// instance 按自然日保存实例用量，删号之后保留（ADR-0036）。
	instance map[string]int64

	// dailyTokens 与 instanceTokens 是配置里的默认额度与实例预算，由 NewHandler
	// 装配时注入；小于等于 0 表示不限。
	dailyTokens          int64
	embeddingDailyTokens int64
	instanceTokens       int64
}

func NewMemoryQuota() *MemoryQuota {
	return &MemoryQuota{
		usage:        make(map[memoryUsageKey]memoryUsageRow),
		limits:       map[[2]string]int64{},
		quotaNotes:   map[string]string{},
		quotaUpdated: map[string]time.Time{},
		instance:     map[string]int64{},
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
	return m.accountUsageLocked(userID, day, kind).Tokens, nil
}

func (m *MemoryQuota) accountUsageLocked(userID, day string, kind Kind) KeyUsageCounts {
	var counts KeyUsageCounts
	for key, row := range m.usage {
		if key.userID == userID && key.day == day && key.kind == kind {
			counts.add(row.KeyUsageCounts)
		}
	}
	return counts
}

func (m *MemoryQuota) Add(_ context.Context, userID, day string, kind Kind, tokens int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	// Add 只用于按账号累加已结算用量，没有密钥可归；与访问令牌调用记在同一行。
	key := memoryUsageKey{userID, day, kind, ""}
	row := m.usage[key]
	row.Tokens += tokens
	m.usage[key] = row
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
	key := memoryUsageKey{userID, day, kind, keyID}
	limit, limited := m.accountLimitLocked(userID, kind)
	free := int64(0)
	if limited {
		counts := m.accountUsageLocked(userID, day, kind)
		free = max(0, limit-counts.Tokens-counts.ReservedTokens)
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
	row := m.usage[key]
	row.ReservedTokens += want
	m.usage[key] = row
	m.instance[day] += instance
	return want, nil
}

func (m *MemoryQuota) Settle(_ context.Context, userID, day string, kind Kind, keyID string, reserved, actual int64, usage Usage, attempt SettleAttempt) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := memoryUsageKey{userID, day, kind, keyID}
	row := m.usage[key]
	// 退回一笔未发送的预留时没有上游用量，最近一次结算的样本继续保留。
	if attempt.Attempts > 0 || usage.Total() > 0 {
		row.last = usage
	}
	row.InputTokens += usage.Input
	row.CachedTokens += usage.Cached
	row.Attempts += max(0, attempt.Attempts)
	row.Failures += max(0, attempt.Failures)

	// 实例账本只加减免费额度内的部分。
	instance := actual - reserved
	if limit, limited := m.accountLimitLocked(userID, kind); limited {
		counts := m.accountUsageLocked(userID, day, kind)
		before := max(0, counts.Tokens+counts.ReservedTokens-reserved)
		free := max(0, limit-before)
		instance = min(actual, free) - min(reserved, free)
	}
	row.ReservedTokens = max(0, row.ReservedTokens-reserved)
	row.Tokens = max(0, row.Tokens+actual)
	if row.KeyUsageCounts == (KeyUsageCounts{}) {
		delete(m.usage, key)
	} else {
		m.usage[key] = row
	}
	m.instance[day] = max(0, m.instance[day]+instance)
	return nil
}

// Split 返回账号当天某类模型最近一次结算记录下来的原始用量，只为核对缓存命中
// 的统计口径；生产走 PostgreSQL，那里的拆分按天累加，这里只留最近一条。
func (m *MemoryQuota) Split(userID, day string, kind Kind) Usage {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.usage[memoryUsageKey{userID, day, kind, ""}].last
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

// PointCharges 在内存实现里没有积分流水：本地联调不配即刻收，后台的积分一节只显示
// 没有开通收款。
func (m *MemoryQuota) PointCharges(context.Context, string, int) ([]PointCharge, error) {
	return nil, nil
}

// RefreshPoints 在内存实现里没有余额可查，报告没有开通收款。
func (m *MemoryQuota) RefreshPoints(context.Context, string) (bool, error) {
	return false, nil
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

// QuotaOverrides 汇总这一批账号里调整过的额度；没有覆盖的账号不出现在结果里。
func (m *MemoryQuota) QuotaOverrides(_ context.Context, userIDs []string) (map[string]QuotaOverride, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]QuotaOverride, len(userIDs))
	for _, userID := range userIDs {
		override := QuotaOverride{}
		found := false
		if limit, ok := m.limits[[2]string{userID, string(KindChat)}]; ok {
			value := limit
			override.DailyTokens = &value
			found = true
		}
		if limit, ok := m.limits[[2]string{userID, string(KindEmbedding)}]; ok {
			value := limit
			override.EmbeddingDailyTokens = &value
			found = true
		}
		if note, ok := m.quotaNotes[userID]; ok {
			override.Note = note
			found = true
		}
		if updated, ok := m.quotaUpdated[userID]; ok {
			override.UpdatedAt = updated
			found = true
		}
		if found {
			out[userID] = override
		}
	}
	return out, nil
}

// SetQuotaOverride 整体替换一个账号的覆盖值；两项都为空且没有备注时删除覆盖，
// 与 PostgreSQL 的 upsert 分支保持同一语义。
func (m *MemoryQuota) SetQuotaOverride(_ context.Context, userID string, daily, embedding *int64, note string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if daily == nil && embedding == nil && note == "" {
		m.clearQuotaOverrideLocked(userID)
		return nil
	}
	m.setLimitLocked(userID, KindChat, daily)
	m.setLimitLocked(userID, KindEmbedding, embedding)
	m.quotaNotes[userID] = note
	m.quotaUpdated[userID] = time.Now().UTC()
	return nil
}

func (m *MemoryQuota) ClearQuotaOverride(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.clearQuotaOverrideLocked(userID)
	return nil
}

func (m *MemoryQuota) setLimitLocked(userID string, kind Kind, limit *int64) {
	key := [2]string{userID, string(kind)}
	if limit == nil {
		delete(m.limits, key)
		return
	}
	m.limits[key] = *limit
}

func (m *MemoryQuota) clearQuotaOverrideLocked(userID string) {
	delete(m.limits, [2]string{userID, string(KindChat)})
	delete(m.limits, [2]string{userID, string(KindEmbedding)})
	delete(m.quotaNotes, userID)
	delete(m.quotaUpdated, userID)
}

// DeleteUser 清掉账号自己的用量与额度覆盖值。实例账本不在这里清：它记录的是
// 提供方已经计费的用量，删号不会让那笔费用消失（ADR-0036）。
func (m *MemoryQuota) DeleteUser(_ context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key := range m.usage {
		if key.userID == userID {
			delete(m.usage, key)
		}
	}
	m.clearQuotaOverrideLocked(userID)
	return nil
}
