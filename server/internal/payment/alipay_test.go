package payment

import (
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
	"testing"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"
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
	gateway, err := NewGateway("2026000000000001",
		c.EncodeToString(x509.MarshalPKCS1PrivateKey(merchantKey)),
		c.EncodeToString(x509.MarshalPKCS1PublicKey(&alipayKey.PublicKey)))
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

// TestCallSignsTheRequestAndVerifiesTheReply 核对公共参数、RSA2 签名与响应验签：
// 请求里的签名能用应用公钥验证，响应只有用支付宝公钥对应的私钥签名才被接受。
func TestCallSignsTheRequestAndVerifiesTheReply(t *testing.T) {
	g, key := testGateway(t)
	const reply = `{"code":"10000","product_name":"知新"}`
	var form url.Values
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		form, _ = url.ParseQuery(string(raw))
		_, _ = fmt.Fprintf(w, `{"alipay_aipay_nowpaydirect_charge_query_response":%s,"sign":%q}`,
			reply, testSignature(t, key, reply))
	}))
	defer server.Close()
	g.endpoint = server.URL

	now := time.Date(2026, 11, 25, 10, 0, 0, 0, time.UTC)
	raw, err := g.call(t.Context(), "alipay.aipay.nowpaydirect.charge.query",
		map[string]any{"out_product_id": "np_1"}, now)
	if err != nil {
		t.Fatalf("验签通过的响应不应失败: %v", err)
	}
	if string(raw) != reply {
		t.Fatalf("应返回业务对象本身，得到 %s", raw)
	}
	if form.Get("app_id") != g.appID ||
		form.Get("method") != "alipay.aipay.nowpaydirect.charge.query" ||
		form.Get("charset") != "utf-8" || form.Get("format") != "JSON" ||
		form.Get("sign_type") != "RSA2" || form.Get("version") != "1.0" ||
		form.Get("timestamp") != "2026-11-25 18:00:00" {
		t.Fatalf("公共参数不符: %v", form)
	}
	if form.Get("biz_content") != `{"out_product_id":"np_1"}` {
		t.Fatalf("biz_content 不符: %s", form.Get("biz_content"))
	}
	signature, err := base64.StdEncoding.DecodeString(form.Get("sign"))
	if err != nil {
		t.Fatalf("sign 不是 base64: %v", err)
	}
	form.Del("sign")
	digest := sha256.Sum256([]byte(signContent(form)))
	if rsa.VerifyPKCS1v15(&g.privateKey.PublicKey, crypto.SHA256, digest[:], signature) != nil {
		t.Fatal("请求签名不能用应用公钥验证")
	}
}

// TestCallRejectsAnUnverifiedReply 核对响应被换掉或签名不对时整体失败，不把
// 未经验证的业务对象交给调用方。
func TestCallRejectsAnUnverifiedReply(t *testing.T) {
	g, _ := testGateway(t)
	stranger, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	const reply = `{"code":"10000"}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, `{"alipay_aipay_nowpaydirect_charge_query_response":%s,"sign":%q}`,
			reply, testSignature(t, stranger, reply))
	}))
	defer server.Close()
	g.endpoint = server.URL

	if _, err := g.Call(t.Context(), "alipay.aipay.nowpaydirect.charge.query",
		map[string]any{"out_product_id": "np_1"}); err == nil {
		t.Fatal("签名不是支付宝的响应必须失败")
	}
}

// TestCallDecodesGB18030Response 即刻收的响应按 GB18030 回中文。签名覆盖原始
// 字节，返回给调用方之前要转成 UTF-8，否则客户端看到的是替换字符。
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

func TestNewGatewayRejectsMismatchedKeys(t *testing.T) {
	merchantKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	c := base64.StdEncoding
	encoded := c.EncodeToString(x509.MarshalPKCS1PrivateKey(merchantKey))
	if _, err := NewGateway("2026000000000001", encoded, encoded); err == nil {
		t.Fatal("应用私钥不能同时当作支付宝公钥")
	}
	if _, err := NewGateway("not-an-app-id", encoded, encoded); err == nil {
		t.Fatal("应用编号必须是数字标识")
	}
}
