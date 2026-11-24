package nowpay

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

type fakePurchases struct {
	latest  Purchase
	has     bool
	created []Purchase
}

func (f *fakePurchases) LatestPurchaseLink(context.Context, string, time.Time) (Purchase, bool, error) {
	return f.latest, f.has, nil
}

func (f *fakePurchases) InsertPurchaseLink(_ context.Context, _ string, purchase Purchase) error {
	f.created = append(f.created, purchase)
	f.latest, f.has = purchase, true
	return nil
}

type fakeLegacy struct{ balance int64 }

func (f fakeLegacy) PurchaseBalance(context.Context, string) (int64, error) { return f.balance, nil }

func newTestHandler(client *Client, purchases *fakePurchases, legacy LegacyBalance) *Handler {
	handler := NewHandler(client, purchases, legacy, "", slog.New(slog.NewTextHandler(io.Discard, nil)), 8)
	handler.limit, handler.global = ratelimit.Disabled(), ratelimit.Disabled()
	return handler
}

func request(method, path, body string) *http.Request {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	return r.WithContext(auth.WithPrincipal(r.Context(), auth.Principal{
		UserID: "user_1", ContactVerified: true,
	}))
}

func decode[T any](t *testing.T, response *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(response.Body.Bytes(), &value); err != nil {
		t.Fatalf("响应不是合法 JSON: %v（%s）", err, response.Body.String())
	}
	return value
}

func TestOverviewWithoutProductReturnsTheLegacyBalanceOnly(t *testing.T) {
	handler := newTestHandler(nil, &fakePurchases{}, fakeLegacy{balance: 5000})
	response := httptest.NewRecorder()
	handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
	if response.Code != http.StatusOK {
		t.Fatalf("未配置商品时应返回 200，得到 %d", response.Code)
	}
	view := decode[api.QuotaPurchaseOverview](t, response)
	if view.Product != nil || view.BalancePoints != 0 || view.LegacyBalanceTokens != 5000 {
		t.Fatalf("未配置商品时只回遗留余额: %+v", view)
	}
}

func TestOverviewReportsProductStatusAndPointsBalance(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT",
			"charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
		methodQuota: `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases, fakeLegacy{balance: 200})
	response := httptest.NewRecorder()
	handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
	if response.Code != http.StatusOK {
		t.Fatalf("查询成功时应返回 200，得到 %d", response.Code)
	}
	view := decode[api.QuotaPurchaseOverview](t, response)
	if view.Product == nil || view.Product.CapabilityStatus != api.ENABLED {
		t.Fatalf("应带上商品状态: %+v", view.Product)
	}
	if len(view.Product.Options) != 1 || view.Product.Options[0].QuotaAmount != 100 {
		t.Fatalf("档位应原样带出: %+v", view.Product.Options)
	}
	if view.BalancePoints != 55 || view.LegacyBalanceTokens != 200 {
		t.Fatalf("余额与遗留余额都应返回: %+v", view)
	}
}

func TestOverviewFailsLoudlyWhenTheBalanceCannotBeRead(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[]}`,
		methodQuota:  `{"code":"20000","sub_code":"isp.unknow-error","sub_msg":"系统繁忙"}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{}, nil)
	response := httptest.NewRecorder()
	handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("余额查询失败不能按 0 余额返回，得到 %d", response.Code)
	}
}

func TestPurchaseRequiresVerifiedContact(t *testing.T) {
	handler := newTestHandler(newTestClient(t, &fakeCaller{}), &fakePurchases{}, nil)
	r := httptest.NewRequest(http.MethodPost, "/v1/me/model-quota-purchases", strings.NewReader(`{}`))
	r = r.WithContext(auth.WithPrincipal(r.Context(), auth.Principal{UserID: "user_1"}))
	response := httptest.NewRecorder()
	handler.Purchase(response, r)
	if response.Code != http.StatusForbidden {
		t.Fatalf("未验证登录方式时不能购买，得到 %d", response.Code)
	}
}

func TestPurchaseRejectsProductsThatAreNotOnSale(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"PENDING","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{}, nil)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
	if response.Code != http.StatusConflict {
		t.Fatalf("商品待审核时不能创单，得到 %d", response.Code)
	}
}

func TestPurchaseRejectsUnknownSKU(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{}, nil)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S9"}`))
	if response.Code != http.StatusConflict {
		t.Fatalf("不在售的档位不能创单，得到 %d", response.Code)
	}
}

func TestPurchaseReturnsTheHostedLinkAndReusesIt(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
		methodPurchase: `{"code":"10000","purchase_url":"alipays://platformapi/startapp?appId=1","purchase_qr_code":"https://mobilecodec.alipay.com/show.htm?code=x","expire_time":"2026-11-25 10:30:00"}`,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases, nil)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
	if response.Code != http.StatusOK {
		t.Fatalf("商品在售时应返回链接，得到 %d（%s）", response.Code, response.Body.String())
	}
	link := decode[api.QuotaPurchaseLink](t, response)
	if link.PurchaseUrl == "" || link.OutRequestNo == "" || link.SkuId == nil || *link.SkuId != "S1" {
		t.Fatalf("购买链接应带请求号与档位: %+v", link)
	}
	if len(purchases.created) != 1 {
		t.Fatalf("应保存一条购买入口请求，实际 %d", len(purchases.created))
	}
	// 同一档位再点一次：复用原链接，不再向即刻收创单。
	second := httptest.NewRecorder()
	handler.Purchase(second, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
	if len(purchases.created) != 1 {
		t.Fatalf("链接有效期内应复用原链接，实际保存 %d 条", len(purchases.created))
	}
	if again := decode[api.QuotaPurchaseLink](t, second); again.OutRequestNo != link.OutRequestNo {
		t.Fatalf("复用的链接请求号应一致: %s 与 %s", again.OutRequestNo, link.OutRequestNo)
	}
}

func TestBalanceEndpointReturnsTheCurrentPoints(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodQuota: `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{}, nil)
	response := httptest.NewRecorder()
	handler.Balance(response, request(http.MethodGet, "/v1/me/model-quota-purchases/quota", ""))
	balance := decode[api.QuotaBalance](t, response)
	if response.Code != http.StatusOK || balance.Remaining != 55 || balance.Total != 100 || balance.Used != 40 {
		t.Fatalf("余额应原样返回: %d %+v", response.Code, balance)
	}
}
