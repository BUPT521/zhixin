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
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	notifyPath = "/v1/payments/alipay/notify"
	alipayTime = "2006-01-02 15:04:05"
)

var (
	chinaTime = time.FixedZone("CST", 8*60*60)
	alipayID  = regexp.MustCompile("^[0-9]{10,32}$")
	tradeID   = regexp.MustCompile("^[0-9]{1,64}$")
	amount    = regexp.MustCompile("^[0-9]{1,8}(\\.[0-9]{1,2})?$")

	ErrInvalidTrade = errors.New("payment: 交易数据不符")
	ErrGateway      = errors.New("payment: 支付宝查单失败")
)

type Gateway struct {
	appID, sellerID, endpoint, notifyURL string
	sandbox                              bool
	privateKey                           *rsa.PrivateKey
	publicKey                            *rsa.PublicKey
	client                               *http.Client
}

func NewGateway(appID, sellerID, notifyURL, privateKey, publicKey string, sandbox bool) (*Gateway, error) {
	callback, err := url.Parse(notifyURL)
	if err != nil || callback.Scheme != "https" || callback.Hostname() == "" ||
		callback.User != nil || callback.RawQuery != "" || callback.ForceQuery ||
		callback.Fragment != "" || callback.EscapedPath() != notifyPath || len(notifyURL) > 256 {
		return nil, errors.New("ZHIXIN_ALIPAY_NOTIFY_URL 必须是指向 " + notifyPath + " 的 HTTPS 地址")
	}
	if !alipayID.MatchString(appID) || !alipayID.MatchString(sellerID) {
		return nil, errors.New("ZHIXIN_ALIPAY_APP_ID 与 ZHIXIN_ALIPAY_SELLER_ID 必须是支付宝分配的数字标识")
	}
	merchantKey, err := parsePrivateKey(privateKey)
	if err != nil {
		return nil, errors.New("ZHIXIN_ALIPAY_PRIVATE_KEY 必须是 2048 位 RSA 应用私钥")
	}
	platformKey, err := parsePublicKey(publicKey)
	if err != nil || merchantKey.N.Cmp(platformKey.N) == 0 {
		return nil, errors.New("ZHIXIN_ALIPAY_PUBLIC_KEY 必须是支付宝的 2048 位 RSA 公钥")
	}
	endpoint := "https://openapi.alipay.com/gateway.do"
	if sandbox {
		endpoint = "https://openapi-sandbox.dl.alipaydev.com/gateway.do"
	}
	return &Gateway{
		appID: appID, sellerID: sellerID, notifyURL: notifyURL, endpoint: endpoint, sandbox: sandbox,
		privateKey: merchantKey, publicKey: platformKey,
		client: &http.Client{
			Timeout:       8 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

func (g *Gateway) Sandbox() bool { return g.sandbox }

func (g *Gateway) signOrder(order Order, now time.Time) (string, error) {
	biz := map[string]any{
		"out_trade_no": order.ID,
		"total_amount": fmt.Sprintf("%d.%02d", order.AmountFen/100, order.AmountFen%100),
		"subject":      "知新聊天额度包",
		"product_code": "QUICK_MSECURITY_PAY",
		"time_expire":  order.ExpiresAt.In(chinaTime).Format(alipayTime),
	}
	return g.sign("alipay.trade.app.pay", biz, now, g.notifyURL)
}

func (g *Gateway) sign(method string, parameters map[string]any, now time.Time, callback string) (string, error) {
	biz, err := json.Marshal(parameters)
	if err != nil {
		return "", err
	}
	form := url.Values{
		"app_id": {g.appID}, "method": {method}, "charset": {"utf-8"}, "format": {"JSON"},
		"sign_type": {"RSA2"}, "timestamp": {now.In(chinaTime).Format(alipayTime)}, "version": {"1.0"},
		"biz_content": {string(biz)},
	}
	if callback != "" {
		form.Set("notify_url", callback)
	}
	digest := sha256.Sum256([]byte(signContent(form, false)))
	signature, err := rsa.SignPKCS1v15(rand.Reader, g.privateKey, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	form.Set("sign", base64.StdEncoding.EncodeToString(signature))
	return form.Encode(), nil
}

type trade struct {
	OrderID string          `json:"out_trade_no"`
	TradeID string          `json:"trade_no"`
	Status  string          `json:"trade_status"`
	Amount  json.RawMessage `json:"total_amount"`
	Code    string          `json:"code"`
	SubCode string          `json:"sub_code"`
}

func (g *Gateway) query(ctx context.Context, orderID string, now time.Time) (trade, error) {
	raw, err := g.call(ctx, "alipay.trade.query", map[string]any{"out_trade_no": orderID}, now)
	if err != nil {
		return trade{}, err
	}
	var result trade
	if json.Unmarshal(raw, &result) != nil {
		return trade{}, ErrGateway
	}
	if result.Code == "40004" && result.SubCode == "ACQ.TRADE_NOT_EXIST" {
		return trade{}, nil
	}
	if result.Code != "10000" || result.OrderID != orderID {
		return trade{}, ErrGateway
	}
	return result, nil
}

// Call 向支付宝网关发起一次业务调用并返回已经验签的业务对象：method 决定接口，
// biz 是 biz_content 的内容。即刻收直连与 APP 支付的网关、签名和公共参数一样，
// 所以六个即刻收接口也走这里（见 internal/nowpay）。
func (g *Gateway) Call(ctx context.Context, method string, biz map[string]any) ([]byte, error) {
	return g.call(ctx, method, biz, time.Now())
}

// call 签名、提交、验签，返回业务对象的原始 JSON。响应里业务对象的键由 method
// 决定，例如 alipay.trade.query 对应 alipay_trade_query_response。
func (g *Gateway) call(ctx context.Context, method string, biz map[string]any, now time.Time) ([]byte, error) {
	body, err := g.sign(method, biz, now, "")
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, g.endpoint, strings.NewReader(body))
	if err != nil {
		return nil, ErrGateway
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := g.client.Do(request)
	if err != nil {
		return nil, ErrGateway
	}
	defer response.Body.Close()
	const maxResponse = 64 << 10
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponse+1))
	if err != nil || len(raw) > maxResponse || response.StatusCode != http.StatusOK {
		return nil, ErrGateway
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal(raw, &envelope) != nil {
		return nil, ErrGateway
	}
	result, ok := envelope[strings.ReplaceAll(method, ".", "_")+"_response"]
	var signature string
	if !ok || json.Unmarshal(envelope["sign"], &signature) != nil || !g.verify(result, signature) {
		return nil, ErrGateway
	}
	return result, nil
}

func (g *Gateway) notification(form url.Values) (trade, error) {
	for _, values := range form {
		if len(values) != 1 {
			return trade{}, ErrInvalidTrade
		}
	}
	if form.Get("sign_type") != "RSA2" || !g.verify([]byte(signContent(form, true)), form.Get("sign")) ||
		form.Get("app_id") != g.appID || form.Get("seller_id") != g.sellerID ||
		form.Get("notify_type") != "trade_status_sync" || form.Get("notify_id") == "" {
		return trade{}, ErrInvalidTrade
	}
	amt, err := json.Marshal(form.Get("total_amount"))
	if err != nil {
		return trade{}, err
	}
	return trade{
		OrderID: form.Get("out_trade_no"), TradeID: form.Get("trade_no"),
		Status: form.Get("trade_status"), Amount: amt,
	}, nil
}

func (g *Gateway) verify(content []byte, signature string) bool {
	decoded, err := base64.StdEncoding.DecodeString(signature)
	if err != nil || len(content) == 0 {
		return false
	}
	digest := sha256.Sum256(content)
	return rsa.VerifyPKCS1v15(g.publicKey, crypto.SHA256, digest[:], decoded) == nil
}

func signContent(form url.Values, notification bool) string {
	keys := make([]string, 0, len(form))
	for key := range form {
		if key != "sign" && !(notification && key == "sign_type") && form.Get(key) != "" {
			keys = append(keys, key)
		}
	}
	slices.Sort(keys)
	fields := make([]string, 0, len(keys))
	for _, key := range keys {
		fields = append(fields, key+"="+form.Get(key))
	}
	return strings.Join(fields, "&")
}

func amountFen(raw json.RawMessage) (int64, error) {
	value := string(raw)
	if strings.HasPrefix(value, "\"") && json.Unmarshal(raw, &value) != nil {
		return 0, ErrInvalidTrade
	}
	if !amount.MatchString(value) {
		return 0, ErrInvalidTrade
	}
	yuan, cents, _ := strings.Cut(value, ".")
	whole, _ := strconv.ParseInt(yuan, 10, 64)
	fraction, _ := strconv.ParseInt((cents + "00")[:2], 10, 64)
	return whole*100 + fraction, nil
}

func decodeKey(raw string) ([]byte, error) {
	if block, rest := pem.Decode([]byte(raw)); block != nil {
		if strings.TrimSpace(string(rest)) != "" {
			return nil, errors.New("extra data after key")
		}
		return block.Bytes, nil
	}
	return base64.StdEncoding.DecodeString(raw)
}

func parsePrivateKey(raw string) (*rsa.PrivateKey, error) {
	der, err := decodeKey(raw)
	if err != nil {
		return nil, err
	}
	key, err := x509.ParsePKCS1PrivateKey(der)
	if err != nil {
		parsed, err := x509.ParsePKCS8PrivateKey(der)
		if err != nil {
			return nil, err
		}
		key, _ = parsed.(*rsa.PrivateKey)
	}
	if key == nil || key.N.BitLen() != 2048 {
		return nil, errors.New("expected 2048-bit RSA private key")
	}
	return key, key.Validate()
}

func parsePublicKey(raw string) (*rsa.PublicKey, error) {
	der, err := decodeKey(raw)
	if err != nil {
		return nil, err
	}
	key, err := x509.ParsePKCS1PublicKey(der)
	if err != nil {
		parsed, err := x509.ParsePKIXPublicKey(der)
		if err != nil {
			return nil, err
		}
		key, _ = parsed.(*rsa.PublicKey)
	}
	if key == nil || key.N.BitLen() != 2048 {
		return nil, errors.New("expected 2048-bit RSA public key")
	}
	return key, nil
}
