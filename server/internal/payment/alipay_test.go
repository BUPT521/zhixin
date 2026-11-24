package payment

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

func testGateway(t *testing.T) (*Gateway, *rsa.PrivateKey) {
	t.Helper()
	merchantKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	alipayKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	c := base64.StdEncoding
	gateway, err := NewGateway("2026000000000001", "2088000000000001",
		"https://pay.example.invalid"+notifyPath,
		c.EncodeToString(x509.MarshalPKCS1PrivateKey(merchantKey)),
		c.EncodeToString(x509.MarshalPKCS1PublicKey(&alipayKey.PublicKey)), true)
	if err != nil {
		t.Fatal(err)
	}
	return gateway, alipayKey
}

func testSignature(t *testing.T, key *rsa.PrivateKey, content string) string {
	t.Helper()
	sum := sha256.Sum256([]byte(content))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

type existingPurchase struct {
	Store
	order Order
}

func (s existingPurchase) FindPurchase(context.Context, string) (Order, error) {
	return s.order, nil
}

func TestCheckoutResumeDoesNotCreateAnotherOrderAfterPayment(t *testing.T) {
	gateway, _ := testGateway(t)
	offer := Offer{AmountFen: 100, Tokens: 20000}
	store := existingPurchase{order: Order{
		ID: "zx_test", UserID: "buyer", Offer: offer, Sandbox: true, AppID: gateway.appID,
		SellerID: gateway.sellerID, Status: Paid, ExpiresAt: time.Now().Add(time.Minute),
	}}
	h := &Handler{
		store: store, gateway: gateway, offer: offer,
		limit: ratelimit.Disabled(), global: ratelimit.Disabled(),
	}
	body := strings.NewReader(`{"offer_id":"chat_100_20000","order_id":"zx_test"}`)
	request := httptest.NewRequest(http.MethodPost, "/v1/me/model-quota-purchases", body)
	request = request.WithContext(auth.WithPrincipal(request.Context(), auth.Principal{
		UserID: "buyer", ContactVerified: true,
	}))
	response := httptest.NewRecorder()
	h.Checkout(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("paid checkout resume = %d, want 409", response.Code)
	}
}

func TestAlipayAppOrderRSA2(t *testing.T) {
	g, _ := testGateway(t)
	now := time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)
	signed, err := g.signOrder(Order{
		ID: "zx_test", Offer: Offer{AmountFen: 101, Tokens: 20000},
		ExpiresAt: now.Add(15 * time.Minute),
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	fields, err := url.ParseQuery(signed)
	if err != nil {
		t.Fatal(err)
	}
	biz := `{"out_trade_no":"zx_test","product_code":"QUICK_MSECURITY_PAY","subject":"知新聊天额度包","time_expire":"2026-11-25 18:15:00","total_amount":"1.01"}`
	canonical := "app_id=2026000000000001&biz_content=" + biz +
		"&charset=utf-8&format=JSON&method=alipay.trade.app.pay&notify_url=https://pay.example.invalid" +
		notifyPath + "&sign_type=RSA2&timestamp=2026-11-25 18:00:00&version=1.0"
	if fields.Get("biz_content") != biz || fields.Get("sign") != testSignature(t, g.privateKey, canonical) {
		t.Fatal("SDK 订单金额、到期时间或 RSA2 签名不符")
	}
}

func TestAlipayNotificationAndQuery(t *testing.T) {
	g, key := testGateway(t)
	order := Order{ID: "zx_test", AppID: g.appID, SellerID: g.sellerID, Sandbox: true, Offer: Offer{AmountFen: 100}}
	form := url.Values{
		"app_id": {g.appID}, "seller_id": {g.sellerID}, "sign_type": {"RSA2"},
		"notify_type": {"trade_status_sync"}, "notify_id": {"notice_1"}, "out_trade_no": {order.ID},
		"trade_no": {"20260000000000000001"}, "trade_status": {"TRADE_SUCCESS"}, "total_amount": {"1.0"},
	}
	form.Set("sign", testSignature(t, key,
		"app_id=2026000000000001&notify_id=notice_1&notify_type=trade_status_sync&out_trade_no=zx_test"+
			"&seller_id=2088000000000001&total_amount=1.0&trade_no=20260000000000000001&trade_status=TRADE_SUCCESS"))
	notice, err := g.notification(form)
	if fen, amountErr := amountFen(notice.Amount); err != nil || amountErr != nil || fen != 100 {
		t.Fatalf("verified notification: amount=%d (%v), notice=%v", fen, amountErr, err)
	}
	form.Set("total_amount", "0.1")
	if _, err := g.notification(form); err == nil {
		t.Fatal("修改金额后不能通过签名校验")
	}
	form.Set("seller_id", "2088000000000002")
	form.Set("sign", testSignature(t, key, signContent(form, true)))
	if _, err := g.notification(form); err == nil {
		t.Fatal("其他收款方即使签名正确也不能确认订单")
	}

	reply := `{"code":"10000","out_trade_no":"zx_test","trade_no":"20260000000000000001","trade_status":"TRADE_SUCCESS","total_amount":1}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, err := io.ReadAll(r.Body)
		fields, formErr := url.ParseQuery(string(raw))
		if err != nil || formErr != nil || fields.Get("method") != "alipay.trade.query" {
			t.Error("查单没有发送表单")
		}
		signature := testSignature(t, key, reply)
		_, _ = fmt.Fprintf(w, `{"alipay_trade_query_response":%s,"sign":%q}`, reply, signature)
	}))
	defer server.Close()
	g.endpoint = server.URL
	result, err := g.query(t.Context(), order.ID, time.Now())
	if fen, amountErr := amountFen(result.Amount); err != nil || amountErr != nil || fen != 100 || result.TradeID != notice.TradeID {
		t.Fatalf("verified query: amount=%d (%v), query=%v", fen, amountErr, err)
	}
	if _, err := g.query(t.Context(), "wrong_order", time.Now()); err == nil {
		t.Fatal("支付宝签名正确的其他订单也不能替代本单")
	}
	for _, value := range []string{`"0.123"`, `"1e2"`, `-1.00`, `true`} {
		if _, err := amountFen(json.RawMessage(value)); err == nil {
			t.Errorf("接受了不合法金额 %s", value)
		}
	}
}

// 即刻收的响应按 GB18030 回中文。签名覆盖原始字节，返回给调用方之前要转成 UTF-8，
// 否则客户端看到的是替换字符。
func TestCallDecodesGB18030Response(t *testing.T) {
	g, key := testGateway(t)
	gbk, err := simplifiedchinese.GB18030.NewEncoder().Bytes([]byte(
		`{"code":"10000","product_name":"知新","charging_options":[{"sku_id":"S1","display_name":"拾伍"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, `{"alipay_aipay_nowpaydirect_charge_query_response":%s,"sign":%q}`,
			gbk, testSignature(t, key, string(gbk)))
	}))
	defer server.Close()
	g.endpoint = server.URL

	raw, err := g.Call(t.Context(), "alipay.aipay.nowpaydirect.charge.query", map[string]any{"out_product_id": "np_1"})
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Product string `json:"product_name"`
		Options []struct {
			Name string `json:"display_name"`
		} `json:"charging_options"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		t.Fatalf("转码之后应当是合法 JSON: %v", err)
	}
	if result.Product != "知新" || len(result.Options) != 1 || result.Options[0].Name != "拾伍" {
		t.Fatalf("中文没有按 GB18030 解码: %+v", result)
	}
}
