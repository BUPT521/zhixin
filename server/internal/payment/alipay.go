// Package payment 封装支付宝网关的 RSA2 签名、验签与调用。
//
// 收款只剩即刻收直连模式（ADR-0067），它复用同一个支付宝应用的应用凭证，所以这里
// 只保留一个 Call：方法名与 biz_content 由 internal/nowpay 给出，应用不再自行
// 构造 APP 支付订单、也不再接收支付宝的异步通知。
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
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

const alipayTime = "2006-01-02 15:04:05"

var (
	chinaTime = time.FixedZone("CST", 8*60*60)
	alipayID  = regexp.MustCompile("^[0-9]{10,32}$")

	// ErrGateway 表示支付宝网关不可用、响应无法验签或业务对象解析失败。调用方
	// 只据此判断“这次没拿到可信结果”，不把上游代码写进对外响应。
	ErrGateway = errors.New("payment: 支付宝网关调用失败")
)

// Gateway 是一个支付宝应用的最小调用入口：应用编号、应用私钥、支付宝公钥与
// 正式网关地址。即刻收没有沙箱网关，所以没有环境切换。
type Gateway struct {
	appID      string
	endpoint   string
	privateKey *rsa.PrivateKey
	publicKey  *rsa.PublicKey
	client     *http.Client
}

// NewGateway 校验应用标识与一对 2048 位 RSA 密钥。应用私钥与支付宝公钥不能是
// 同一把钥匙，否则谁也证明不了响应来自支付宝。
func NewGateway(appID, privateKey, publicKey string) (*Gateway, error) {
	if !alipayID.MatchString(appID) {
		return nil, errors.New("ZHIXIN_ALIPAY_APP_ID 必须是支付宝分配的数字标识")
	}
	merchantKey, err := parsePrivateKey(privateKey)
	if err != nil {
		return nil, errors.New("ZHIXIN_ALIPAY_PRIVATE_KEY 必须是 2048 位 RSA 应用私钥")
	}
	platformKey, err := parsePublicKey(publicKey)
	if err != nil || merchantKey.N.Cmp(platformKey.N) == 0 {
		return nil, errors.New("ZHIXIN_ALIPAY_PUBLIC_KEY 必须是支付宝的 2048 位 RSA 公钥")
	}
	return &Gateway{
		appID: appID, endpoint: "https://openapi.alipay.com/gateway.do",
		privateKey: merchantKey, publicKey: platformKey,
		client: &http.Client{
			Timeout:       8 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

// Call 向支付宝网关发起一次业务调用并返回已经验签的业务对象：method 决定接口，
// biz 是 biz_content 的内容。
func (g *Gateway) Call(ctx context.Context, method string, biz map[string]any) ([]byte, error) {
	return g.call(ctx, method, biz, time.Now())
}

// call 签名、提交、验签，返回业务对象的原始 JSON。响应里业务对象的键由 method
// 决定，例如 alipay.trade.query 对应 alipay_trade_query_response。
func (g *Gateway) call(ctx context.Context, method string, biz map[string]any, now time.Time) ([]byte, error) {
	body, err := g.sign(method, biz, now)
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
	// 即刻收的响应把中文按 GB18030 回，请求里写 charset=utf-8 也不改。签名覆盖的是
	// 原始字节，所以先验签再转码；转码失败就按原样返回，让调用方看到错误而不是乱码。
	if !utf8.Valid(result) {
		if decoded, err := simplifiedchinese.GB18030.NewDecoder().Bytes(result); err == nil {
			result = decoded
		}
	}
	return result, nil
}

func (g *Gateway) sign(method string, parameters map[string]any, now time.Time) (string, error) {
	biz, err := json.Marshal(parameters)
	if err != nil {
		return "", err
	}
	form := url.Values{
		"app_id": {g.appID}, "method": {method}, "charset": {"utf-8"}, "format": {"JSON"},
		"sign_type": {"RSA2"}, "timestamp": {now.In(chinaTime).Format(alipayTime)}, "version": {"1.0"},
		"biz_content": {string(biz)},
	}
	digest := sha256.Sum256([]byte(signContent(form)))
	signature, err := rsa.SignPKCS1v15(rand.Reader, g.privateKey, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	form.Set("sign", base64.StdEncoding.EncodeToString(signature))
	return form.Encode(), nil
}

func (g *Gateway) verify(content []byte, signature string) bool {
	decoded, err := base64.StdEncoding.DecodeString(signature)
	if err != nil || len(content) == 0 {
		return false
	}
	digest := sha256.Sum256(content)
	return rsa.VerifyPKCS1v15(g.publicKey, crypto.SHA256, digest[:], decoded) == nil
}

func signContent(form url.Values) string {
	keys := make([]string, 0, len(form))
	for key := range form {
		if key != "sign" && form.Get(key) != "" {
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
