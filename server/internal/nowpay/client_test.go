package nowpay

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/payment"
)

// fakeCaller 记录每次调用的 method 与 biz，并返回预先写好的业务对象。
type fakeCaller struct {
	mu      sync.Mutex
	methods []string
	biz     []map[string]any
	replies map[string]string
	err     error
	// blockQuota 非空时 quota.query 阻塞到它被关闭，用来验证余额刷新不占核销的时间
	// 预算。
	blockQuota chan struct{}
	// started 与 release 非空时，每次调用先往 started 发一个 method，再等 release
	// 关闭，用来验证概览的两次查询是并行的。
	started chan string
	release chan struct{}
	// failPurchase 是接下来多少次 purchase.create 直接失败，用来验证创单失败之后
	// 按原请求号重试。
	failPurchase int
}

func (f *fakeCaller) Call(_ context.Context, method string, biz map[string]any) ([]byte, error) {
	f.mu.Lock()
	f.methods = append(f.methods, method)
	f.biz = append(f.biz, biz)
	f.mu.Unlock()
	if method == methodPurchase && f.failPurchase > 0 {
		f.failPurchase--
		return nil, errors.New("支付宝网关超时")
	}
	if f.started != nil {
		f.started <- method
	}
	if f.release != nil {
		<-f.release
	}
	if method == methodQuota && f.blockQuota != nil {
		<-f.blockQuota
	}
	if f.err != nil {
		return nil, f.err
	}
	return []byte(f.replies[method]), nil
}

// calls 返回已经发生的调用方法，供并发用例在同步之后读取。
func (f *fakeCaller) calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.methods...)
}

func newTestClient(t *testing.T, caller Caller) *Client {
	t.Helper()
	client, err := NewClient(caller, "np_d_f83a7c91")
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestChargeReadsCapabilityAndOptions(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodCharge: `{
		"code":"10000","capability_status":"ENABLED","product_name":"知新聊天额度",
		"billing_mode":"QUANTITY","quota_unit":"POINT",
		"charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}],
		"management_url":"alipays://platformapi/startapp"
	}`}}
	capability, err := newTestClient(t, caller).Charge(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if caller.methods[0] != methodCharge {
		t.Fatalf("method = %s", caller.methods[0])
	}
	if caller.biz[0]["out_product_id"] != "np_d_f83a7c91" {
		t.Fatalf("biz_content 缺少商品 ID: %v", caller.biz[0])
	}
	if !capability.Purchasable() || capability.BillingMode != BillingQuantity || capability.QuotaUnit != UnitPoints {
		t.Fatalf("收费能力解析错误: %+v", capability)
	}
	if len(capability.Options) != 1 || capability.Options[0].Quota != 100 || capability.Options[0].Price != "6.00" {
		t.Fatalf("档位解析错误: %+v", capability.Options)
	}
}

func TestCapabilityNotEnabledIsNotPurchasable(t *testing.T) {
	// 商品不可售时也可能返回档位，不能只看档位列表非空。
	caller := &fakeCaller{replies: map[string]string{methodCharge: `{
		"code":"10000","capability_status":"PENDING","billing_mode":"QUANTITY","quota_unit":"POINT",
		"charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]
	}`}}
	capability, err := newTestClient(t, caller).Charge(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if capability.Purchasable() {
		t.Fatal("PENDING 不算可售")
	}
}

func TestBalanceRemainingIsKeptSeparateFromTotalMinusUsed(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodQuota: `{
		"code":"10000","quota_unit":"POINT","total":200,"used":50,"remaining":140,"as_of_time":"2026-11-25 10:00:00"
	}`}}
	balance, err := newTestClient(t, caller).Balance(context.Background(), "user_1")
	if err != nil {
		t.Fatal(err)
	}
	if balance.Remaining != 140 {
		t.Fatalf("remaining 必须用返回的余额，不能是 total-used: %+v", balance)
	}
	if caller.biz[0]["external_buyer_id"] != "user_1" {
		t.Fatalf("受益人标识应取知新账号: %v", caller.biz[0])
	}
	want := time.Date(2026, 11, 25, 10, 0, 0, 0, payment.ChinaTime())
	if !balance.AsOf.Equal(want) {
		t.Fatalf("快照时间应取响应里的 as_of_time，得到 %v", balance.AsOf)
	}
}

// TestBalanceFallsBackToTheQueryStartWithoutASnapshotTime 守住没有 as_of_time 时的
// 处理：用查询发起的时刻写副本，而不是零值（ADR-0073）。
func TestBalanceFallsBackToTheQueryStartWithoutASnapshotTime(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodQuota: `{
		"code":"10000","quota_unit":"POINT","total":200,"used":50,"remaining":140
	}`}}
	before := time.Now()
	balance, err := newTestClient(t, caller).Balance(context.Background(), "user_1")
	after := time.Now()
	if err != nil {
		t.Fatal(err)
	}
	if balance.AsOf.Before(before) || balance.AsOf.After(after) {
		t.Fatalf("没有 as_of_time 时应按查询发起的时刻，得到 %v", balance.AsOf)
	}
}

func TestPurchaseSendsSKUAndParsesExpiry(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodPurchase: `{
		"code":"10000","purchase_url":"alipays://platformapi/startapp?appId=1","purchase_qr_code":"https://mobilecodec.alipay.com/show.htm?code=x",
		"expire_time":"2026-11-25 10:30:00"
	}`}}
	link, err := newTestClient(t, caller).Purchase(context.Background(), PurchaseRequest{
		OutRequestNo: "np_1", Buyer: "user_1", SKU: "S1", CallbackURL: "https://app.example.com/nowpay/return",
	})
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{
		"out_request_no": "np_1", "sku_id": "S1", "external_buyer_id": "user_1",
		"callback_url": "https://app.example.com/nowpay/return",
	} {
		if caller.biz[0][key] != want {
			t.Errorf("biz_content[%s] = %v，应为 %s", key, caller.biz[0][key], want)
		}
	}
	want := time.Date(2026, 11, 25, 10, 30, 0, 0, payment.ChinaTime())
	if !link.ExpiresAt.Equal(want) {
		t.Fatalf("链接失效时间按东八区解析错误: %v", link.ExpiresAt)
	}
	if link.URL == "" {
		t.Fatal("缺少购买链接")
	}
}

func TestVerifyRequiresPositiveAmountAndReturnsProcessing(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodVerify: `{
		"code":"10000","consume_status":"PROCESSING","quota_unit":"POINT"
	}`}}
	client := newTestClient(t, caller)
	consume, err := client.Verify(context.Background(), VerifyRequest{
		OutRequestNo: "nc_1", Buyer: "user_1", Amount: 3, Reason: consumeReason,
	})
	if err != nil {
		t.Fatal(err)
	}
	if consume.Status != ConsumeProcessing || consume.Confirmed() {
		t.Fatalf("PROCESSING 不能算成功: %+v", consume)
	}
	if caller.biz[0]["amount"] != int64(3) {
		t.Fatalf("amount 必须显式传入: %v", caller.biz[0])
	}
	if _, err := client.Verify(context.Background(), VerifyRequest{OutRequestNo: "nc_2", Buyer: "user_1"}); err == nil {
		t.Fatal("没有金额的核销不能发出")
	}
}

func TestRefreshUsesOriginalRequestNoWithoutAmount(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodRefresh: `{
		"code":"10000","consume_status":"SUCCEEDED","consumed":3,"remaining":97
	}`}}
	consume, err := newTestClient(t, caller).Refresh(context.Background(), VerifyRequest{
		OutRequestNo: "nc_1", Buyer: "user_1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if caller.methods[0] != methodRefresh {
		t.Fatalf("method = %s", caller.methods[0])
	}
	if _, ok := caller.biz[0]["amount"]; ok {
		t.Fatal("查询核销结果不应重复传入金额")
	}
	if !consume.Confirmed() || consume.Consumed != 3 || consume.Remaining != 97 {
		t.Fatalf("核销结果解析错误: %+v", consume)
	}
}

func TestBusinessErrorCodeIsReportedWithSubCode(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodVerify: `{
		"code":"40004","msg":"Business Failed","sub_code":"NOW_PAY_QUOTA_INSUFFICIENT","sub_msg":"额度不足"
	}`}}
	_, err := newTestClient(t, caller).Verify(context.Background(), VerifyRequest{
		OutRequestNo: "nc_1", Buyer: "user_1", Amount: 1, Reason: consumeReason,
	})
	if !Insufficient(err) {
		t.Fatalf("余额不足应能被识别: %v", err)
	}
	var api *APIError
	if !errors.As(err, &api) || api.SubCode != insufficientCode {
		t.Fatalf("错误应带 sub_code: %v", err)
	}
}

func TestGatewayFailureWrapsIntoError(t *testing.T) {
	caller := &fakeCaller{err: errors.New("支付宝查单失败")}
	_, err := newTestClient(t, caller).Balance(context.Background(), "user_1")
	if err == nil || !strings.Contains(err.Error(), methodQuota) {
		t.Fatalf("网关失败应指出是哪一次调用: %v", err)
	}
	if Insufficient(err) {
		t.Fatal("网关失败不能当成余额不足")
	}
}

func TestPointsRoundsUp(t *testing.T) {
	for _, test := range []struct{ tokens, perPoint, want int64 }{
		{0, 1000, 0}, {1, 1000, 1}, {999, 1000, 1}, {1000, 1000, 1}, {1001, 1000, 2},
		{2500, 1000, 3}, {-5, 1000, 0}, {100, 0, 0},
	} {
		if got := Points(test.tokens, test.perPoint); got != test.want {
			t.Errorf("Points(%d, %d) = %d，应为 %d", test.tokens, test.perPoint, got, test.want)
		}
	}
}

// 响应里出现新的核销状态时不能猜成成功或失败，按未知处理。
func TestUnknownConsumeStatusIsAnError(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{methodVerify: `{"code":"10000","consume_status":"REVERSED"}`}}
	_, err := newTestClient(t, caller).Verify(context.Background(), VerifyRequest{
		OutRequestNo: "nc_1", Buyer: "user_1", Amount: 1, Reason: consumeReason,
	})
	if err == nil {
		t.Fatal("未知核销状态应当报错，交给待确认流程")
	}
}

func TestClientRejectsEmptyProductIDAndBuyer(t *testing.T) {
	if _, err := NewClient(&fakeCaller{}, "  "); err == nil {
		t.Fatal("没有商品 ID 不能构造客户端")
	}
	if _, err := NewClient(nil, "np_1"); err == nil {
		t.Fatal("没有网关不能构造客户端")
	}
	client := newTestClient(t, &fakeCaller{})
	if _, err := client.Balance(context.Background(), ""); err == nil {
		t.Fatal("没有受益人标识不能查询余额")
	}
}

// 业务对象里出现非预期字段时不应影响解析。
func TestChargeIgnoresUnknownFields(t *testing.T) {
	raw := `{"code":"10000","capability_status":"ENABLED","charging_options":[],"extra":{"a":1}}`
	var result struct {
		Status string `json:"capability_status"`
	}
	if err := json.Unmarshal([]byte(raw), &result); err != nil || result.Status != "ENABLED" {
		t.Fatalf("未知字段不应导致解析失败: %v", err)
	}
}
