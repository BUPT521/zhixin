// Package nowpay 封装即刻收直连模式：查商品收费能力、取托管购买页链接、查积分
// 余额、核销与查询核销结果，以及按计费 token 折算积分并把核销记进本地流水。
//
// 即刻收的商品在「即刻收」小程序里配置，收费模式、档位与价格都由它给出，应用不能
// 定价，也不能自己发明商品 ID。网关、RSA2 签名与公共参数跟 APP 支付完全一样，
// 所以这里只向 payment.Gateway 要一个 Call，不另引支付宝 SDK。
//
// 页面返回与到账是两件事：callback_url 只决定支付页返回之后跳到哪里，凭余额或
// 权益接口重新查询才决定能不能放行，见 docs/adr/0067。
package nowpay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"strings"
	"time"
)

// 接口名是支付宝的 method 参数，签名覆盖的 biz_content 由各方法自己给出。
const (
	methodCharge   = "alipay.aipay.nowpaydirect.charge.query"
	methodPurchase = "alipay.aipay.nowpaydirect.purchase.create"
	methodQuota    = "alipay.aipay.nowpaydirect.quota.query"
	methodVerify   = "alipay.aipay.nowpaydirect.quota.verify"
	methodRefresh  = "alipay.aipay.nowpaydirect.quota.refresh"
)

// 商品收费能力。只有 ENABLED 表示允许新增购买，下架不等于已有权益失效。
const (
	CapabilityEnabled = "ENABLED"
	BillingQuantity   = "QUANTITY"
	UnitPoints        = "POINT"
)

// 核销结果。只有 SUCCEEDED 表示这次扣减已经发生，PROCESSING 与未知状态都要用原
// 请求号继续查，不能换号重扣。
const (
	ConsumeSucceeded  = "SUCCEEDED"
	ConsumeFailed     = "FAILED"
	ConsumeProcessing = "PROCESSING"
)

// 余额不足既是业务错误码，也可能是 FAILED 的结果表达，两处都要认。
const insufficientCode = "NOW_PAY_QUOTA_INSUFFICIENT"

// Caller 是支付宝网关的调用入口，由 payment.Gateway 实现；测试里换成假网关。
type Caller interface {
	Call(ctx context.Context, method string, biz map[string]any) ([]byte, error)
}

// APIError 是支付宝返回的网关或业务错误码。客户端按 Code 与 SubCode 分支，不解析
// SubMsg 的文案。
type APIError struct {
	Method  string
	Code    string
	SubCode string
	SubMsg  string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("nowpay: %s 返回 %s/%s（%s）", e.Method, e.Code, e.SubCode, e.SubMsg)
}

// Insufficient 报告这次核销是否因为积分不足而未确认成功。
func Insufficient(err error) bool {
	var api *APIError
	return errors.As(err, &api) && api.SubCode == insufficientCode
}

// Option 是商品的一个档位。价格由即刻收给出，单位元，应用只展示不参与创单。
type Option struct {
	SKU   string
	Name  string
	Price string
	Quota int64
}

// Capability 是商品当前的收费能力。
type Capability struct {
	Status      string
	BillingMode string
	QuotaUnit   string
	Name        string
	Options     []Option
}

// Purchasable 报告这个商品现在是否允许新增购买。档位非空不代表可售，只有
// capability_status 是 ENABLED 才算。
func (c Capability) Purchasable() bool { return c.Status == CapabilityEnabled }

// Balance 是账号在商品下的积分余额。Remaining 已经排除预占，不能用 Total-Used
// 代替。
type Balance struct {
	Unit      string
	Total     int64
	Used      int64
	Remaining int64
}

// Link 是一次购买入口。URL 与二维码按不透明链接使用，不解析、不拼接。
type Link struct {
	URL       string
	QRCode    string
	ExpiresAt time.Time
}

// PurchaseRequest 是取购买链接的入参。OutRequestNo 是幂等号，重试必须保持原值。
type PurchaseRequest struct {
	OutRequestNo string
	Buyer        string
	SKU          string
	CallbackURL  string
}

// VerifyRequest 是一次核销。Amount 是本次要扣的积分数；OutRequestNo 是消费请求号，
// 结果未知时只能用这个号查询或重试。
type VerifyRequest struct {
	OutRequestNo string
	Buyer        string
	Amount       int64
	Reason       string
}

// Consume 是核销或核销查询的结果。Status 之外的字段只在 SUCCEEDED 时可用，
// PROCESSING 时缺失的值保持零值而不补猜。
type Consume struct {
	Status    string
	Consumed  int64
	Remaining int64
}

// Confirmed 报告这次核销是否已经确认扣减。
func (c Consume) Confirmed() bool { return c.Status == ConsumeSucceeded }

// Client 是一个商品下的即刻收调用入口。
type Client struct {
	caller    Caller
	productID string
	china     *time.Location
}

// NewClient 绑定一个商品。productID 来自小程序商品详情，不能由应用生成。
func NewClient(caller Caller, productID string) (*Client, error) {
	if caller == nil {
		return nil, errors.New("nowpay: 需要支付宝网关")
	}
	if strings.TrimSpace(productID) == "" {
		return nil, errors.New("nowpay: 需要即刻收商品 ID")
	}
	return &Client{caller: caller, productID: productID, china: chinaTime()}, nil
}

// ChinaTime 返回东八区时间，用于解析即刻收给出的时刻。
func ChinaTime() *time.Location { return chinaTime() }

var shanghai = func() *time.Location {
	zone, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		return time.FixedZone("CST", 8*60*60)
	}
	return zone
}()

func chinaTime() *time.Location { return shanghai }

// Charge 查询商品收费能力与档位。
func (c *Client) Charge(ctx context.Context) (Capability, error) {
	var result struct {
		Code             string `json:"code"`
		SubCode          string `json:"sub_code"`
		SubMsg           string `json:"sub_msg"`
		CapabilityStatus string `json:"capability_status"`
		ProductName      string `json:"product_name"`
		BillingMode      string `json:"billing_mode"`
		QuotaUnit        string `json:"quota_unit"`
		Options          []struct {
			SKUID       string `json:"sku_id"`
			DisplayName string `json:"display_name"`
			Price       string `json:"price"`
			QuotaAmount int64  `json:"quota_amount"`
		} `json:"charging_options"`
	}
	if err := c.do(ctx, methodCharge, map[string]any{"out_product_id": c.productID}, &result); err != nil {
		return Capability{}, err
	}
	capability := Capability{
		Status: result.CapabilityStatus, BillingMode: result.BillingMode,
		QuotaUnit: result.QuotaUnit, Name: result.ProductName,
		Options: make([]Option, 0, len(result.Options)),
	}
	for _, option := range result.Options {
		capability.Options = append(capability.Options, Option{
			SKU: option.SKUID, Name: option.DisplayName, Price: option.Price, Quota: option.QuotaAmount,
		})
	}
	return capability, nil
}

// Balance 查询账号在这个商品下的积分余额。未购买时三项都是 0，查询失败不能按
// 零余额处理，所以失败一律返回错误。
func (c *Client) Balance(ctx context.Context, buyer string) (Balance, error) {
	if err := validBuyer(buyer); err != nil {
		return Balance{}, err
	}
	var result struct {
		Code      string `json:"code"`
		SubCode   string `json:"sub_code"`
		SubMsg    string `json:"sub_msg"`
		QuotaUnit string `json:"quota_unit"`
		Total     int64  `json:"total"`
		Used      int64  `json:"used"`
		Remaining int64  `json:"remaining"`
	}
	biz := map[string]any{"out_product_id": c.productID, "external_buyer_id": buyer}
	if err := c.do(ctx, methodQuota, biz, &result); err != nil {
		return Balance{}, err
	}
	return Balance{
		Unit: result.QuotaUnit, Total: result.Total, Used: result.Used, Remaining: result.Remaining,
	}, nil
}

// Purchase 取一个购买入口。不传 SKU 时由用户在托管购买页选择档位。
func (c *Client) Purchase(ctx context.Context, req PurchaseRequest) (Link, error) {
	if err := validBuyer(req.Buyer); err != nil {
		return Link{}, err
	}
	if req.OutRequestNo == "" {
		return Link{}, errors.New("nowpay: 购买入口请求号不能为空")
	}
	biz := map[string]any{
		"out_request_no": req.OutRequestNo, "out_product_id": c.productID, "external_buyer_id": req.Buyer,
	}
	if req.SKU != "" {
		biz["sku_id"] = req.SKU
	}
	if req.CallbackURL != "" {
		biz["callback_url"] = req.CallbackURL
	}
	var result struct {
		Code       string `json:"code"`
		SubCode    string `json:"sub_code"`
		SubMsg     string `json:"sub_msg"`
		Purchase   string `json:"purchase_url"`
		QRCode     string `json:"purchase_qr_code"`
		ExpireTime string `json:"expire_time"`
	}
	if err := c.do(ctx, methodPurchase, biz, &result); err != nil {
		return Link{}, err
	}
	if result.Purchase == "" {
		return Link{}, &APIError{Method: methodPurchase, Code: "10000", SubMsg: "响应缺少购买链接"}
	}
	expires, err := time.ParseInLocation("2006-01-02 15:04:05", result.ExpireTime, c.china)
	if err != nil {
		return Link{}, &APIError{Method: methodPurchase, Code: "10000", SubMsg: "购买链接缺少有效期"}
	}
	return Link{URL: result.Purchase, QRCode: result.QRCode, ExpiresAt: expires}, nil
}

// Verify 核销一笔消费。只有 SUCCEEDED 表示扣减已经发生；PROCESSING 与任何未知
// 结果都要用同一个 OutRequestNo 重新查询。
func (c *Client) Verify(ctx context.Context, req VerifyRequest) (Consume, error) {
	if err := validBuyer(req.Buyer); err != nil {
		return Consume{}, err
	}
	if req.OutRequestNo == "" || req.Amount <= 0 || req.Reason == "" {
		return Consume{}, errors.New("nowpay: 核销需要请求号、正整数金额与消费说明")
	}
	biz := map[string]any{
		"out_request_no": req.OutRequestNo, "out_product_id": c.productID,
		"external_buyer_id": req.Buyer, "amount": req.Amount, "consume_reason": req.Reason,
	}
	return c.consume(ctx, methodVerify, biz)
}

// Refresh 用原请求号查询一次核销的结果。它不会补扣，也不会改变余额。
func (c *Client) Refresh(ctx context.Context, req VerifyRequest) (Consume, error) {
	if err := validBuyer(req.Buyer); err != nil {
		return Consume{}, err
	}
	if req.OutRequestNo == "" {
		return Consume{}, errors.New("nowpay: 查询核销结果需要原请求号")
	}
	biz := map[string]any{
		"out_request_no": req.OutRequestNo, "out_product_id": c.productID, "external_buyer_id": req.Buyer,
	}
	return c.consume(ctx, methodRefresh, biz)
}

func (c *Client) consume(ctx context.Context, method string, biz map[string]any) (Consume, error) {
	var result struct {
		Code        string `json:"code"`
		SubCode     string `json:"sub_code"`
		SubMsg      string `json:"sub_msg"`
		ConsumeStat string `json:"consume_status"`
		Consumed    *int64 `json:"consumed"`
		Remaining   *int64 `json:"remaining"`
	}
	if err := c.do(ctx, method, biz, &result); err != nil {
		return Consume{}, err
	}
	consume := Consume{Status: result.ConsumeStat}
	if result.Consumed != nil {
		consume.Consumed = *result.Consumed
	}
	if result.Remaining != nil {
		consume.Remaining = *result.Remaining
	}
	switch consume.Status {
	case ConsumeSucceeded, ConsumeFailed, ConsumeProcessing:
	default:
		return Consume{}, &APIError{Method: method, Code: "10000", SubMsg: "未知的核销状态 " + consume.Status}
	}
	return consume, nil
}

// do 调用一个接口，先看网关与业务错误码，再把业务对象解进 out。code=10000 只说
// 明接口调用成功，能不能购买、扣减有没有发生还要看各自的业务字段。
func (c *Client) do(ctx context.Context, method string, biz map[string]any, out any) error {
	raw, err := c.caller.Call(ctx, method, biz)
	if err != nil {
		return fmt.Errorf("nowpay: 调用 %s 失败: %w", method, err)
	}
	var status struct {
		Code    string `json:"code"`
		SubCode string `json:"sub_code"`
		SubMsg  string `json:"sub_msg"`
	}
	if err := json.Unmarshal(raw, &status); err != nil {
		return fmt.Errorf("nowpay: 解析 %s 响应失败: %w", method, err)
	}
	if status.Code != "10000" || status.SubCode != "" {
		return &APIError{Method: method, Code: status.Code, SubCode: status.SubCode, SubMsg: status.SubMsg}
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("nowpay: 解析 %s 业务字段失败: %w", method, err)
	}
	return nil
}

func validBuyer(buyer string) error {
	if strings.TrimSpace(buyer) == "" || len(buyer) > 128 {
		return errors.New("nowpay: 受益人标识必须是知新的账号编号")
	}
	return nil
}

// Points 把计费 token 折算成积分，向上取整：一个积分覆盖 TokensPerPoint 个计费
// token，不满一个积分的余量也按一个积分计。调用方传入当天累计量并减去当天已申请
// 的积分，只补差额，多记的量因此整天不超过一个积分，见 ADR-0067。
func Points(tokens, tokensPerPoint int64) int64 {
	if tokens <= 0 || tokensPerPoint <= 0 {
		return 0
	}
	return (tokens + tokensPerPoint - 1) / tokensPerPoint
}
