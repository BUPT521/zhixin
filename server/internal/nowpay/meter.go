package nowpay

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"sync"
	"time"
)

// 核销流水的状态。pending 表示已经写进本地、还没有向即刻收发起核销；processing
// 表示发起过但结果未知；succeeded 表示确认扣减；failed 表示确认没有扣减。
const (
	StatusPending    = "pending"
	StatusProcessing = "processing"
	StatusSucceeded  = "succeeded"
	StatusFailed     = "failed"
)

// consumeReason 是提交给即刻收的消费说明。它只写业务类别，不写提示词、用户内容或
// 业务 JSON，最长 256 字符。
const consumeReason = "知新聊天额度"

// Charge 是一笔积分核销流水。ID 既是本地主键，也是向即刻收提交的 out_request_no：
// 结果未知时只能用它查询或重试，不能换号重扣。
type Charge struct {
	ID     string
	UserID string
	Day    string
	Points int64
	Tokens int64
	Status string
}

// Ledger 保存核销流水，由 store/pg 实现。ReservePoints 必须在同一个事务里比较当天
// 已申请量与 required 再决定写不写，否则两个并发结算会各按旧值再扣一次；余额副本
// 也要在同一个事务与同一把锁里读，收口之后的申请量不会被并发的余额更新推翻
// （ADR-0073）。
type Ledger interface {
	ReservePoints(ctx context.Context, charge Charge, required int64) (Charge, bool, error)
	Unsettled(ctx context.Context, userID string, limit int) ([]Charge, error)
	// UnsettledGlobal 取全局创建早于 before 且仍未终结的流水，供每十分钟一次的补查
	// 兜底；它不按账号过滤。
	UnsettledGlobal(ctx context.Context, before time.Time, limit int) ([]Charge, error)
	// SetStatus 落流水状态并返回这次的确认时刻；写余额副本时用它做快照的下限，
	// 这一笔才不会被算成“快照之后才确认”（ADR-0073）。
	SetStatus(ctx context.Context, id, status, note string) (time.Time, error)
	// SaveBalance 用即刻收报告的剩余积分覆盖本地余额副本，asOf 是这份余额对应的
	// 快照时刻，不是写入时刻；晚到的旧快照不会覆盖新副本（ADR-0073）。额度预留按
	// 这份副本放行免费额度之外的用量，请求路径上因此不调用即刻收（ADR-0069）。
	SaveBalance(ctx context.Context, userID string, remaining int64, asOf time.Time) error
}

// BalanceRefreshAfter 是余额副本需要重新查询的间隔。副本缺失或距上次快照超过它时，
// 预留排一次异步查询，这一轮仍按旧值判断，下一次请求才能看到新值；预留因此不会在
// 请求路径上等待即刻收（ADR-0073）。
const BalanceRefreshAfter = time.Minute

// refreshInterval 是同一账号两次余额查询的最小间隔。额度用完之后的每个请求都会
// 发现副本过期，网关故障时查询也会失败、副本保持过期，不合并就会让每个被拒的请求
// 都排一次查询，把核销队列占住。
const refreshInterval = time.Minute

// Recorder 是模型代理结算之后的核销入口，由 pg 存储在结算提交后调用；未配置即刻收
// 时它保持为空，整条路径不启用。
type Recorder interface {
	// Record 按这次结算之后应当由积分承担的计费 token 数差额核销。它只写本地流水
	// 并把核销排进队列，不阻塞请求，失败由下次请求前的补查接手。
	Record(ctx context.Context, userID, day string, chargeableTokens int64)
	// Resume 把账号尚未终结的流水排进队列补查。
	Resume(ctx context.Context, userID string)
	// RefreshBalance 排一次余额查询，供额度预留发现副本缺失或过期时调用；它不阻塞
	// 请求，并报告这次是否真的入了队：同一个账号一分钟内已经排过时返回 false。
	// 429 的原因据此区分“正在同步”与“确实没有积分”（ADR-0073）。
	RefreshBalance(ctx context.Context, userID string) bool
	// TokensPerPoint 是一个积分覆盖的计费 token 数，额度预留按它把余额折成 token。
	TokensPerPoint() int64
}

// Meter 把计费 token 折成积分、写待核销流水并异步核销。
//
// 交付与核销的先后是“先交付后核销”：模型的回答已经发给用户之后才记账，核销失败
// 不回滚回答，留在 pending 或 processing 的流水由下一轮请求前补查，见 ADR-0067。
// 核销与余额刷新分两条队列：余额查询是外部调用，不能占住核销的时间预算，队列满时
// 直接丢弃并在下一次请求时重新合并（ADR-0073）。
type Meter struct {
	client   *Client
	ledger   Ledger
	perPoint int64
	log      *slog.Logger
	// queue 是核销与补查队列，容量按一次补查能带上的流水数留足；满了只记日志，
	// 流水留在本地，下一轮请求或全局补查接手。
	queue chan job
	// refreshQueue 是余额刷新队列。查询失败或队列满都只影响副本的同步时间，不阻塞
	// 核销，也不阻塞请求。
	refreshQueue chan job

	// refreshAt 记每个账号最近一次排进队列的余额查询时间，键在合并窗口过去之后
	// 清理，map 不随注册过的账号数一直增长。
	mu        sync.Mutex
	refreshAt map[string]time.Time
}

type job struct {
	charge Charge
	// verify 为真表示这是第一次核销，为假表示用原请求号补查结果。
	verify bool
	// balance 为真表示这是一次余额刷新，此时 charge 不用，只查 userID 的余额。
	balance bool
	userID  string
}

// 队列容量与两类任务的时间预算。余额刷新的超时短于核销，查询变慢时先放弃刷新，
// 把时间留给已经在队列里的核销。
const (
	chargeQueueSize  = 256
	refreshQueueSize = 64
	chargeTimeout    = 20 * time.Second
	refreshTimeout   = 8 * time.Second
)

// NewMeter 装配一个核销执行器。perPoint 是一个积分覆盖的计费 token 数，来自配置。
func NewMeter(client *Client, ledger Ledger, perPoint int64, log *slog.Logger) (*Meter, error) {
	if client == nil || ledger == nil {
		return nil, errors.New("nowpay: 核销需要即刻收客户端与流水存储")
	}
	if perPoint < 1 {
		return nil, errors.New("nowpay: 一个积分覆盖的计费 token 数必须是正整数")
	}
	if log == nil {
		log = slog.Default()
	}
	return &Meter{
		client: client, ledger: ledger, perPoint: perPoint, log: log,
		queue: make(chan job, chargeQueueSize), refreshQueue: make(chan job, refreshQueueSize),
		refreshAt: map[string]time.Time{},
	}, nil
}

// Start 启动两个协程：核销与补查一条，余额刷新一条，ctx 结束时一起退出。队列外的
// 调用方都不等待它们。
func (m *Meter) Start(ctx context.Context) {
	go m.loop(ctx, m.queue)
	go m.loop(ctx, m.refreshQueue)
}

func (m *Meter) loop(ctx context.Context, queue <-chan job) {
	for {
		select {
		case <-ctx.Done():
			return
		case next := <-queue:
			m.run(ctx, next)
		}
	}
}

// Record 按当天累计应当由积分承担的计费 token 数核销差额，传入的不是单轮用量。
// 当天已经申请过的积分（含待确认与处理中）先扣掉，所以同一轮结算重入不会重复扣款，
// 一整天多记的积分也不超过一个。余额副本已知时由 ReservePoints 在同一个事务里按
// 可用积分收口，余额不足的申请不会每轮重复写一条流水、再核销失败一次（ADR-0073）。
func (m *Meter) Record(ctx context.Context, userID, day string, chargeableTokens int64) {
	required := Points(chargeableTokens, m.perPoint)
	if required <= 0 {
		return
	}
	charge := Charge{
		ID: newChargeID(), UserID: userID, Day: day,
		Tokens: chargeableTokens, Status: StatusPending,
	}
	reserved, ok, err := m.ledger.ReservePoints(ctx, charge, required)
	if err != nil {
		m.log.Error("reserve nowpay points", "user_id", userID, "day", day, "error", err)
		return
	}
	if !ok {
		return
	}
	m.enqueue(job{charge: reserved, verify: true})
}

// Resume 把还没有确认结果的流水排进队列：pengding 的用原参数重试核销，processing
// 的只查结果。重试核销带原请求号，支付宝按幂等处理，不会重复扣；而只查结果的流量
// 在“上一次请求根本没到”时永远查不到记录，所以两种状态分开处理。查询失败不影响这
// 一轮请求：流水留在原状态，下一轮再查。
func (m *Meter) Resume(ctx context.Context, userID string) {
	charges, err := m.ledger.Unsettled(ctx, userID, 4)
	if err != nil {
		m.log.Error("read unsettled nowpay charges", "user_id", userID, "error", err)
		return
	}
	for _, charge := range charges {
		m.enqueue(job{charge: charge, verify: charge.Status == StatusPending})
	}
}

// RefreshBalance 排一次余额查询并覆盖本地副本。额度预留发现副本缺失或超过
// BalanceRefreshAfter 时调用它；这一轮请求按旧值判断，下一次请求才能看到新余额。
// 同一账号在 refreshInterval 内只排一次，连续被拒的请求不会各自再排。返回值表示这次
// 是否真的入了刷新队列，429 据此给出“正在同步”（ADR-0073）。
func (m *Meter) RefreshBalance(_ context.Context, userID string) bool {
	if userID == "" || !m.markRefresh(userID) {
		return false
	}
	if m.enqueue(job{balance: true, userID: userID}) {
		return true
	}
	// 队列满时这次查询没排上，合并窗口不能先占住：这一分钟内的下一次请求还要能
	// 再排一次，否则 429 会退化成 account/points，用户被引导去买积分（ADR-0073）。
	m.forgetRefresh(userID)
	return false
}

// markRefresh 记下这次余额查询并报告是否要真的排队；同一个账号在合并窗口内重复
// 请求时返回 false。
func (m *Meter) markRefresh(userID string) bool {
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	if last, ok := m.refreshAt[userID]; ok && now.Sub(last) < refreshInterval {
		return false
	}
	// 表变大时清掉已经过窗口的键；小表不扫，省掉每次请求的整表遍历。
	if len(m.refreshAt) > 1024 {
		for id, at := range m.refreshAt {
			if now.Sub(at) >= refreshInterval {
				delete(m.refreshAt, id)
			}
		}
	}
	m.refreshAt[userID] = now
	return true
}

// forgetRefresh 退回已经占住的合并窗口。只有队列没排上时才调用：那种情况下这一轮
// 的余额查询并没有发生，窗口还应当留给下一次请求。
func (m *Meter) forgetRefresh(userID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.refreshAt, userID)
}

// TokensPerPoint 是一个积分覆盖的计费 token 数，额度预留按它把余额折成 token。
func (m *Meter) TokensPerPoint() int64 { return m.perPoint }

// enqueue 把任务放进对应的队列，不阻塞，返回是否真的入了队。核销队列满时流水留在
// 本地，下一轮请求或全局补查接手；刷新队列满时直接丢弃，同一账号一分钟内的下一次
// 请求会重新合并一次查询。
func (m *Meter) enqueue(next job) bool {
	queue := m.queue
	if next.balance {
		queue = m.refreshQueue
	}
	select {
	case queue <- next:
		return true
	default:
		if next.balance {
			m.log.Warn("balance refresh queue is full; dropping it and merging into the next request",
				"user_id", next.userID)
			return false
		}
		m.log.Warn("nowpay queue is full; leaving the charge for the next request",
			"charge_id", next.charge.ID)
		return false
	}
}

// run 执行一次核销、补查或余额刷新，并把结果落到流水或余额副本上。asOf 是发起
// 核销的时刻，核销结果没有携带快照时间时用它写副本（ADR-0073）。余额刷新用更短的
// 超时，查询变慢时放弃刷新，不占用核销的时间预算。
func (m *Meter) run(parent context.Context, next job) {
	timeout := chargeTimeout
	if next.balance {
		timeout = refreshTimeout
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), timeout)
	defer cancel()
	if next.balance {
		m.refresh(ctx, next.userID)
		return
	}
	asOf := time.Now()
	request := VerifyRequest{
		OutRequestNo: next.charge.ID, Buyer: next.charge.UserID,
		Amount: next.charge.Points, Reason: consumeReason,
	}
	var (
		consume Consume
		err     error
	)
	if next.verify {
		consume, err = m.client.Verify(ctx, request)
	} else {
		consume, err = m.client.Refresh(ctx, request)
	}
	m.apply(ctx, next.charge, consume, err, asOf)
}

// refresh 查一次余额并覆盖本地副本。查询失败只记日志，副本停在旧值：把失败当成零
// 余额会把还在余额内的账号挡在免费额度之外。
func (m *Meter) refresh(ctx context.Context, userID string) {
	balance, err := m.client.Balance(ctx, userID)
	if err != nil {
		m.log.Warn("refresh the nowpay balance", "user_id", userID, "error", err)
		return
	}
	if balance.Unit != UnitPoints {
		// 不是按积分卖的商品，余额数字不能写进按积分放行的副本。
		m.log.Error("the nowpay product is not sold in points",
			"user_id", userID, "quota_unit", balance.Unit)
		return
	}
	m.saveBalance(ctx, userID, balance.Remaining, balance.AsOf)
}

// saveBalance 覆盖本地余额副本。写失败只影响下一轮预留的判断，下一轮请求会再查。
func (m *Meter) saveBalance(ctx context.Context, userID string, points int64, asOf time.Time) {
	if userID == "" {
		return
	}
	if err := m.ledger.SaveBalance(ctx, userID, points, asOf); err != nil {
		m.log.Error("save the nowpay balance", "user_id", userID, "error", err)
	}
}

// apply 按核销结果落状态。只有 SUCCEEDED 记成功；FAILED 与余额不足记失败，让下次
// 结算重新算差额；处理中与未知结果保持原状态，等下一次补查。
//
// 响应里带了剩余积分时覆盖余额副本：额度预留按这份副本放行，它比下一次查询更早
// 反映这次扣减。PROCESSING 不覆盖副本：它返回的剩余积分是否已经扣住这笔预占还没有
// 与即刻收确认，拿来当余额可能让副本偏低（ADR-0073）。
//
// 确认成功或失败时先落状态再写副本，副本的快照时刻取响应给出时刻与这次确认时刻里
// 较晚的一个：终态行的 updated_at 就是确认时间，早于它的快照会把这一笔算成“快照
// 之后才确认”，可用积分平白少一笔（ADR-0073）。
func (m *Meter) apply(ctx context.Context, charge Charge, consume Consume, err error, asOf time.Time) {
	if !consume.AsOf.IsZero() {
		asOf = consume.AsOf
	}
	if err == nil && consume.Unit != "" && consume.Unit != UnitPoints {
		// 商品的额度单位不是 POINT 时，扣减不能按积分记，也不写副本；记失败让下一次
		// 结算重新算，单位恢复之后还能补上。
		m.log.Error("the nowpay response is not in points",
			"charge_id", charge.ID, "quota_unit", consume.Unit)
		m.setStatus(ctx, charge, StatusFailed, "积分单位不是 POINT")
		return
	}
	switch {
	case err == nil && consume.Confirmed():
		confirmed := m.setStatus(ctx, charge, StatusSucceeded, "")
		if consume.RemainingKnown {
			m.saveBalance(ctx, charge.UserID, consume.Remaining, laterOf(asOf, confirmed))
		}
	case err == nil && consume.Status == ConsumeFailed:
		confirmed := m.setStatus(ctx, charge, StatusFailed, "即刻收判定本次核销失败")
		if consume.RemainingKnown {
			m.saveBalance(ctx, charge.UserID, consume.Remaining, laterOf(asOf, confirmed))
		}
	case err == nil && consume.Status == ConsumeProcessing:
		m.setStatus(ctx, charge, StatusProcessing, "")
	case Insufficient(err):
		m.setStatus(ctx, charge, StatusFailed, "积分不足")
		// 余额不足说明副本比实际高，按零覆盖，下一次预留不再按旧值放行；真正的
		// 余额在下一次查询或下一次成功核销时补回来。
		m.saveBalance(ctx, charge.UserID, 0, asOf)
	default:
		// 超时、网关错误与未知状态都不能判失败：扣减可能已经发生，换号重扣会多收
		// 一次。保留原状态与原请求号，下一轮补查。
		m.log.Warn("nowpay charge is not settled yet",
			"charge_id", charge.ID, "status", charge.Status, "error", err)
		if err != nil {
			if _, noteErr := m.ledger.SetStatus(ctx, charge.ID, "", err.Error()); noteErr != nil {
				m.log.Error("note nowpay charge", "charge_id", charge.ID, "error", noteErr)
			}
		}
	}
}

// laterOf 取两个快照时刻里较晚的一个，零值表示没有这个时刻。写副本时响应给出的
// 快照时刻可能早于本地确认时刻，取较晚的一个才不会把刚确认的这一笔算成之后才确认。
func laterOf(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// setStatus 落一次状态并返回确认时刻；失败时返回零值，调用方按没有这个时刻处理。
func (m *Meter) setStatus(ctx context.Context, charge Charge, status, note string) time.Time {
	at, err := m.ledger.SetStatus(ctx, charge.ID, status, note)
	if err != nil {
		m.log.Error("settle nowpay charge", "charge_id", charge.ID, "status", status, "error", err)
		return time.Time{}
	}
	return at
}

// newChargeID 生成本地流水编号，同时作为即刻收的 out_request_no；长度与字符集都在
// 支付宝要求的 128 个字符以内。
func newChargeID() string { return newID("nc_") }

// newID 生成带前缀的随机标识，随机源只用于编号，不参与安全判断。
func newID(prefix string) string {
	var random [16]byte
	_, _ = rand.Read(random[:])
	return prefix + hex.EncodeToString(random[:])
}
