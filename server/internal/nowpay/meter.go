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
// 已申请量与 required 再决定写不写，否则两个并发结算会各按旧值再扣一次。
type Ledger interface {
	ReservePoints(ctx context.Context, charge Charge, required int64) (Charge, bool, error)
	// AvailablePoints 返回本地余额副本里的可用积分。known 为假表示副本缺失或余额表
	// 未就绪，此时不能按副本截断申请量，见 Meter.Record。
	AvailablePoints(ctx context.Context, userID string) (int64, bool, error)
	Unsettled(ctx context.Context, userID string, limit int) ([]Charge, error)
	SetStatus(ctx context.Context, id, status, note string) error
	// SaveBalance 用即刻收报告的剩余积分覆盖本地余额副本。额度预留按这份副本放行
	// 免费额度之外的用量，请求路径上因此不调用即刻收（ADR-0069）。
	SaveBalance(ctx context.Context, userID string, remaining int64) error
}

// BalanceTTL 是本地余额副本可以用于放行的最长时间。超过它仍然按旧值放行这一轮，
// 同时排一次异步查询，下一次请求就能看到新值；预留因此不会在请求路径上等待即刻收。
const BalanceTTL = 10 * time.Minute

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
	// RefreshBalance 排一次余额查询，供额度预留发现副本缺失或过期时调用；它不返回
	// 查询结果，也不阻塞请求。
	RefreshBalance(ctx context.Context, userID string)
	// TokensPerPoint 是一个积分覆盖的计费 token 数，额度预留按它把余额折成 token。
	TokensPerPoint() int64
}

// Meter 把计费 token 折成积分、写待核销流水并异步核销。
//
// 交付与核销的先后是“先交付后核销”：模型的回答已经发给用户之后才记账，核销失败
// 不回滚回答，留在 pending 或 processing 的流水由下一轮请求前补查，见 ADR-0067。
type Meter struct {
	client   *Client
	ledger   Ledger
	perPoint int64
	log      *slog.Logger
	queue    chan job

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
		queue: make(chan job, 256), refreshAt: map[string]time.Time{},
	}, nil
}

// Start 启动唯一的核销协程并在 ctx 结束时退出。队列外的调用方不等待它。
func (m *Meter) Start(ctx context.Context) {
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case next := <-m.queue:
				m.run(ctx, next)
			}
		}
	}()
}

// Record 按当天累计应当由积分承担的计费 token 数核销差额，传入的不是单轮用量。
// 当天已经申请过的积分（含待确认与处理中）先扣掉，所以同一轮结算重入不会重复扣款，
// 一整天多记的积分也不超过一个。余额副本已知时再按它收口，余额不足的申请不会每轮
// 重复写一条流水、再核销失败一次，见 capToBalance。
func (m *Meter) Record(ctx context.Context, userID, day string, chargeableTokens int64) {
	required := Points(chargeableTokens, m.perPoint)
	if required <= 0 {
		return
	}
	required, ok := m.capToBalance(ctx, userID, required)
	if !ok {
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

// capToBalance 按本地余额副本收口本次申请量，第二个返回值表示是否还要申请。failed
// 流水不计入当天已申请量，余额不足时若照旧整额申请，每一轮结算都会再写一条流水、再
// 核销失败一次；副本已知不超过零时直接不申请。副本小于 required 时截到副本，先扣掉
// 部分余额，避免余额一直攒着不动，差额等余额补上之后的下一次结算再算。副本未知
// （没有行或余额表未就绪）或读取失败时保持原值，与按副本放行之前的做法一致。
func (m *Meter) capToBalance(ctx context.Context, userID string, required int64) (int64, bool) {
	available, known, err := m.ledger.AvailablePoints(ctx, userID)
	if err != nil {
		m.log.Error("read the nowpay balance copy", "user_id", userID, "error", err)
		return required, true
	}
	if !known {
		return required, true
	}
	if available <= 0 {
		return 0, false
	}
	if available < required {
		return available, true
	}
	return required, true
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
// BalanceTTL 时调用它；这一轮请求按旧值判断，下一次请求才能看到新余额。同一账号
// 在 refreshInterval 内只排一次，连续被拒的请求不会各自再排。
func (m *Meter) RefreshBalance(_ context.Context, userID string) {
	if userID == "" || !m.markRefresh(userID) {
		return
	}
	m.enqueue(job{balance: true, userID: userID})
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

// TokensPerPoint 是一个积分覆盖的计费 token 数，额度预留按它把余额折成 token。
func (m *Meter) TokensPerPoint() int64 { return m.perPoint }

// enqueue 不阻塞：队列满时流水留在本地，下一轮请求前补查。
func (m *Meter) enqueue(next job) {
	select {
	case m.queue <- next:
	default:
		m.log.Warn("nowpay queue is full; leaving the charge for the next request",
			"charge_id", next.charge.ID)
	}
}

// run 执行一次核销、补查或余额刷新，并把结果落到流水或余额副本上。
func (m *Meter) run(parent context.Context, next job) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), 20*time.Second)
	defer cancel()
	if next.balance {
		m.refresh(ctx, next.userID)
		return
	}
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
	m.apply(ctx, next.charge, consume, err)
}

// refresh 查一次余额并覆盖本地副本。查询失败只记日志，副本停在旧值：把失败当成零
// 余额会把还在余额内的账号挡在免费额度之外。
func (m *Meter) refresh(ctx context.Context, userID string) {
	balance, err := m.client.Balance(ctx, userID)
	if err != nil {
		m.log.Warn("refresh the nowpay balance", "user_id", userID, "error", err)
		return
	}
	m.saveBalance(ctx, userID, balance.Remaining)
}

// saveBalance 覆盖本地余额副本。写失败只影响下一轮预留的判断，下一轮请求会再查。
func (m *Meter) saveBalance(ctx context.Context, userID string, points int64) {
	if userID == "" {
		return
	}
	if err := m.ledger.SaveBalance(ctx, userID, points); err != nil {
		m.log.Error("save the nowpay balance", "user_id", userID, "error", err)
	}
}

// apply 按核销结果落状态。只有 SUCCEEDED 记成功；FAILED 与余额不足记失败，让下次
// 结算重新算差额；处理中与未知结果保持原状态，等下一次补查。
//
// 响应里带了剩余积分就覆盖余额副本：额度预留按这份副本放行，它比下一次查询更早
// 反映这次扣减。
func (m *Meter) apply(ctx context.Context, charge Charge, consume Consume, err error) {
	if consume.RemainingKnown {
		m.saveBalance(ctx, charge.UserID, consume.Remaining)
	}
	switch {
	case err == nil && consume.Confirmed():
		m.setStatus(ctx, charge, StatusSucceeded, "")
	case err == nil && consume.Status == ConsumeFailed:
		m.setStatus(ctx, charge, StatusFailed, "即刻收判定本次核销失败")
	case err == nil && consume.Status == ConsumeProcessing:
		m.setStatus(ctx, charge, StatusProcessing, "")
	case Insufficient(err):
		m.setStatus(ctx, charge, StatusFailed, "积分不足")
		// 余额不足说明副本比实际高，按零覆盖，下一次预留不再按旧值放行；真正的
		// 余额在下一次查询或下一次成功核销时补回来。
		m.saveBalance(ctx, charge.UserID, 0)
	default:
		// 超时、网关错误与未知状态都不能判失败：扣减可能已经发生，换号重扣会多收
		// 一次。保留原状态与原请求号，下一轮补查。
		m.log.Warn("nowpay charge is not settled yet",
			"charge_id", charge.ID, "status", charge.Status, "error", err)
		if err != nil {
			if noteErr := m.ledger.SetStatus(ctx, charge.ID, "", err.Error()); noteErr != nil {
				m.log.Error("note nowpay charge", "charge_id", charge.ID, "error", noteErr)
			}
		}
	}
}

func (m *Meter) setStatus(ctx context.Context, charge Charge, status, note string) {
	if err := m.ledger.SetStatus(ctx, charge.ID, status, note); err != nil {
		m.log.Error("settle nowpay charge", "charge_id", charge.ID, "status", status, "error", err)
	}
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
