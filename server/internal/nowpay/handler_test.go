package nowpay

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
)

// fakePurchases 是购买入口存储的内存实现：按幂等键存行，LockPurchase 用一把单独的
// 互斥锁模拟真实实现里的 advisory lock。
type fakePurchases struct {
	lockMu  sync.Mutex
	mu      sync.Mutex
	byKey   map[string]Purchase
	latest  Purchase
	has     bool
	created []Purchase
	// failCreate 让用例模拟写库失败。
	failCreate error
}

func (f *fakePurchases) LatestPurchaseLink(context.Context, string, time.Time) (Purchase, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.latest, f.has, nil
}

func (f *fakePurchases) PurchaseByClientRequestNo(_ context.Context, _, clientRequestNo string) (Purchase, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	purchase, ok := f.byKey[clientRequestNo]
	return purchase, ok, nil
}

func (f *fakePurchases) CreatePurchaseLink(_ context.Context, _ string, purchase Purchase) error {
	if f.failCreate != nil {
		return f.failCreate
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.byKey == nil {
		f.byKey = map[string]Purchase{}
	}
	if _, exists := f.byKey[purchase.ClientRequestNo]; exists {
		return errors.New("duplicate client_request_no")
	}
	f.byKey[purchase.ClientRequestNo] = purchase
	f.created = append(f.created, purchase)
	return nil
}

func (f *fakePurchases) ReplacePurchaseLink(_ context.Context, _ string, purchase Purchase) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.byKey == nil {
		f.byKey = map[string]Purchase{}
	}
	f.byKey[purchase.ClientRequestNo] = purchase
	f.created = append(f.created, purchase)
	return nil
}

func (f *fakePurchases) ReadyPurchaseLink(_ context.Context, outRequestNo, url string, expiresAt time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for key, purchase := range f.byKey {
		if purchase.OutRequestNo != outRequestNo {
			continue
		}
		purchase.URL, purchase.ExpiresAt, purchase.State = url, expiresAt, PurchaseReady
		f.byKey[key] = purchase
		f.latest, f.has = purchase, true
	}
	return nil
}

func (f *fakePurchases) FailPurchaseLink(_ context.Context, outRequestNo string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for key, purchase := range f.byKey {
		if purchase.OutRequestNo == outRequestNo {
			purchase.State = PurchaseFailed
			f.byKey[key] = purchase
		}
	}
	return nil
}

func (f *fakePurchases) LockPurchase(ctx context.Context, _, _ string, fn func(context.Context) error) error {
	f.lockMu.Lock()
	defer f.lockMu.Unlock()
	return fn(ctx)
}

type fakeBalances struct {
	saved map[string]int64
	asOf  map[string]time.Time
}

func (f *fakeBalances) SaveBalance(_ context.Context, userID string, remaining int64, asOf time.Time) error {
	if f.saved == nil {
		f.saved = map[string]int64{}
		f.asOf = map[string]time.Time{}
	}
	f.saved[userID] = remaining
	f.asOf[userID] = asOf
	return nil
}

func newTestHandler(client *Client, purchases *fakePurchases) *Handler {
	return newTestHandlerWith(client, purchases, &fakeBalances{})
}

func newTestHandlerWith(client *Client, purchases *fakePurchases, balances *fakeBalances) *Handler {
	handler := NewHandler(client, purchases, balances, "", slog.New(slog.NewTextHandler(io.Discard, nil)), 8, 10000)
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

func TestOverviewWithoutProductReturnsTheDefaultRatio(t *testing.T) {
	handler := newTestHandler(nil, &fakePurchases{})
	response := httptest.NewRecorder()
	handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
	if response.Code != http.StatusOK {
		t.Fatalf("未配置商品时应返回 200，得到 %d", response.Code)
	}
	view := decode[api.QuotaPurchaseOverview](t, response)
	if view.Product != nil || view.BalancePoints != 0 {
		t.Fatalf("未配置商品时不回商品与积分: %+v", view)
	}
	if view.TokensPerPoint != 10000 {
		t.Fatalf("未配置商品时仍按默认比例返回: %+v", view)
	}
}

func TestOverviewReturnsTheConfiguredTokensPerPoint(t *testing.T) {
	handler := NewHandler(nil, &fakePurchases{}, &fakeBalances{}, "",
		slog.New(slog.NewTextHandler(io.Discard, nil)), 8, 500)
	handler.limit, handler.global = ratelimit.Disabled(), ratelimit.Disabled()
	response := httptest.NewRecorder()
	handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
	view := decode[api.QuotaPurchaseOverview](t, response)
	if view.TokensPerPoint != 500 {
		t.Fatalf("概览应原样返回配置的比例: %+v", view)
	}
}

func TestOverviewReportsProductStatusAndPointsBalance(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT",
			"charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
		methodQuota: `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
	}}
	purchases := &fakePurchases{}
	balances := &fakeBalances{}
	handler := newTestHandlerWith(newTestClient(t, caller), purchases, balances)
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
	if view.BalancePoints != 55 {
		t.Fatalf("余额应返回: %+v", view)
	}
	// 查到的余额也要落进本地副本，额度预留按它放行（ADR-0069）。
	if balances.saved["user_1"] != 55 {
		t.Fatalf("概览查到的余额应写进副本: %+v", balances.saved)
	}
}

// TestOverviewReportsABalanceThatCannotBeRead 守住概览页的容错：余额查询失败时不再
// 整页 503，商品信息照常返回，只把余额标成暂时不可用（ADR-0073）。
func TestOverviewReportsABalanceThatCannotBeRead(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[]}`,
		methodQuota:  `{"code":"20000","sub_code":"isp.unknow-error","sub_msg":"系统繁忙"}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{})
	response := httptest.NewRecorder()
	handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
	if response.Code != http.StatusOK {
		t.Fatalf("余额查不到时应返回 200 并标记不可用，得到 %d", response.Code)
	}
	view := decode[api.QuotaPurchaseOverview](t, response)
	if view.Product == nil || view.Product.CapabilityStatus != api.ENABLED {
		t.Fatalf("商品信息应照常返回: %+v", view.Product)
	}
	if view.BalanceUnavailable == nil || !*view.BalanceUnavailable {
		t.Fatalf("余额查不到时应标记 balance_unavailable: %+v", view)
	}
}

// TestOverviewQueriesProductAndBalanceInParallel 守住概览的两次网关调用并行：串行时
// 用户要等两次往返，余额查询变慢会把商品信息一起拖住。
func TestOverviewQueriesProductAndBalanceInParallel(t *testing.T) {
	started := make(chan string, 2)
	release := make(chan struct{})
	caller := &fakeCaller{
		started: started,
		release: release,
		replies: map[string]string{
			methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[]}`,
			methodQuota:  `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
		},
	}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{})
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
		close(done)
	}()
	seen := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case method := <-started:
			seen[method] = true
		case <-time.After(2 * time.Second):
			t.Fatalf("两次查询没有并行发出，只看到 %v", seen)
		}
	}
	close(release)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("概览没有返回")
	}
	if !seen[methodCharge] || !seen[methodQuota] {
		t.Fatalf("应同时查商品与余额: %v", seen)
	}
}

// TestOverviewCachesTheProductCapability 守住六十秒缓存：同一实例上反复打开概览时，
// 商品能力不必每次都查，余额仍然每次实时查。
func TestOverviewCachesTheProductCapability(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[]}`,
		methodQuota:  `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{})
	for i := 0; i < 2; i++ {
		response := httptest.NewRecorder()
		handler.Overview(response, request(http.MethodGet, "/v1/me/model-quota-purchases", ""))
		if response.Code != http.StatusOK {
			t.Fatalf("概览应返回 200，得到 %d", response.Code)
		}
	}
	var charges, quotes int
	for _, method := range caller.calls() {
		switch method {
		case methodCharge:
			charges++
		case methodQuota:
			quotes++
		}
	}
	if charges != 1 || quotes != 2 {
		t.Fatalf("商品能力应缓存、余额应每次查，实际 charge=%d quota=%d", charges, quotes)
	}
}

func TestPurchaseRequiresVerifiedContact(t *testing.T) {
	handler := newTestHandler(newTestClient(t, &fakeCaller{}), &fakePurchases{})
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
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{})
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
	if response.Code != http.StatusConflict {
		t.Fatalf("商品待审核时不能创单，得到 %d", response.Code)
	}
}

// TestPurchaseRejectsProductsThatAreNotSoldInPoints 守住商品单位校验：只有按积分卖
// 的数量包能接进额度放行，其它收费模式明确失败，不创单（ADR-0073）。
func TestPurchaseRejectsProductsThatAreNotSoldInPoints(t *testing.T) {
	for name, capability := range map[string]string{
		"计次包": `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"COUNT","charging_options":[{"sku_id":"S1","display_name":"十次","price":"6.00","quota_amount":10}]}`,
		"买断包": `{"code":"10000","capability_status":"ENABLED","billing_mode":"ONE_TIME","quota_unit":"POINT","charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			caller := &fakeCaller{replies: map[string]string{methodCharge: capability}}
			purchases := &fakePurchases{}
			handler := newTestHandler(newTestClient(t, caller), purchases)
			response := httptest.NewRecorder()
			handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
			if response.Code != http.StatusConflict {
				t.Fatalf("单位不是积分时不能创单，得到 %d", response.Code)
			}
			if len(purchases.created) != 0 {
				t.Fatalf("单位不是积分时不该创单: %+v", purchases.created)
			}
		})
	}
}

func TestPurchaseRejectsUnknownSKU(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge: `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`,
	}}
	handler := newTestHandler(newTestClient(t, caller), &fakePurchases{})
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S9"}`))
	if response.Code != http.StatusConflict {
		t.Fatalf("不在售的档位不能创单，得到 %d", response.Code)
	}
}

// purchaseCapability 是测试里通用的在售积分商品回复。
const purchaseCapability = `{"code":"10000","capability_status":"ENABLED","billing_mode":"QUANTITY","quota_unit":"POINT","charging_options":[{"sku_id":"S1","display_name":"100 积分","price":"6.00","quota_amount":100}]}`

// purchaseReply 是测试里通用的购买入口回复：有效期远在测试之后。
const purchaseReply = `{"code":"10000","purchase_url":"alipays://platformapi/startapp?appId=1","purchase_qr_code":"https://mobilecodec.alipay.com/show.htm?code=x","expire_time":"2099-11-25 10:30:00"}`

func TestPurchaseReturnsTheHostedLink(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	if response.Code != http.StatusOK {
		t.Fatalf("商品在售时应返回链接，得到 %d（%s）", response.Code, response.Body.String())
	}
	link := decode[api.QuotaPurchaseLink](t, response)
	if link.PurchaseUrl == "" || link.OutRequestNo == "" || link.SkuId == nil || *link.SkuId != "S1" {
		t.Fatalf("购买链接应带请求号与档位: %+v", link)
	}
	if len(purchases.created) != 1 || purchases.created[0].State != PurchaseCreating {
		t.Fatalf("应先落一条 creating 行，实际 %+v", purchases.created)
	}
}

// TestPurchaseSameClientRequestNoReusesTheLink 守住一次点击一个幂等键：同一个键重试
// 返回同一张链接，不再创单（ADR-0074）。
func TestPurchaseSameClientRequestNoReusesTheLink(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	first := httptest.NewRecorder()
	handler.Purchase(first, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	firstLink := decode[api.QuotaPurchaseLink](t, first)
	second := httptest.NewRecorder()
	handler.Purchase(second, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	if second.Code != http.StatusOK {
		t.Fatalf("同键重试应返回链接，得到 %d", second.Code)
	}
	secondLink := decode[api.QuotaPurchaseLink](t, second)
	if secondLink.OutRequestNo != firstLink.OutRequestNo {
		t.Fatalf("同键应复用同一张链接: %s 与 %s", secondLink.OutRequestNo, firstLink.OutRequestNo)
	}
	var creates int
	for _, method := range caller.calls() {
		if method == methodPurchase {
			creates++
		}
	}
	if creates != 1 {
		t.Fatalf("同键重试不应再创单，实际 purchase.create 调用 %d 次", creates)
	}
}

// TestPurchaseDifferentClientRequestNoCreatesNewLinks 守住换一次点击换一张链接：不同
// 的键一定拿到新链接，支付成功之后再点不会打开已经付过的页面（ADR-0074）。
func TestPurchaseDifferentClientRequestNoCreatesNewLinks(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	first := httptest.NewRecorder()
	handler.Purchase(first, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	second := httptest.NewRecorder()
	handler.Purchase(second, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-2"}`))
	if firstLink, secondLink := decode[api.QuotaPurchaseLink](t, first), decode[api.QuotaPurchaseLink](t, second); firstLink.OutRequestNo == secondLink.OutRequestNo {
		t.Fatalf("不同的键应拿到不同的请求号: %s", firstLink.OutRequestNo)
	}
	if len(purchases.created) != 2 {
		t.Fatalf("不同的键应各落一行，实际 %d 行", len(purchases.created))
	}
}

// TestPurchaseRetriesACreatingEntryWithTheSameRequestNo 守住创单中断之后的恢复：同一
// 个键停在 creating 时按原请求号重试，不换号重扣（ADR-0074）。
func TestPurchaseRetriesACreatingEntryWithTheSameRequestNo(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{byKey: map[string]Purchase{
		"req-1": {
			OutRequestNo: "np_stuck", ClientRequestNo: "req-1", SKU: "S1",
			State: PurchaseCreating, ExpiresAt: time.Now().Add(10 * time.Minute),
		},
	}}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	if response.Code != http.StatusOK {
		t.Fatalf("creating 的同键重试应返回链接，得到 %d", response.Code)
	}
	if purchases.byKey["req-1"].OutRequestNo != "np_stuck" || len(purchases.created) != 0 {
		t.Fatalf("应复用原来的请求号，不新建行: %+v", purchases.created)
	}
	var sent string
	for i, method := range caller.calls() {
		if method == methodPurchase {
			sent = caller.biz[i]["out_request_no"].(string)
		}
	}
	if sent != "np_stuck" {
		t.Fatalf("重试应带原请求号，实际 %q", sent)
	}
	if purchases.byKey["req-1"].State != PurchaseReady {
		t.Fatalf("创单成功后应转 ready: %+v", purchases.byKey["req-1"])
	}
}

// TestPurchaseReplacesAnExpiredEntry 守住过期之后的重新创单：同一个键在过期或失败之后
// 换一个新请求号替换整行（ADR-0074）。
func TestPurchaseReplacesAnExpiredEntry(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{byKey: map[string]Purchase{
		"req-1": {
			OutRequestNo: "np_old", ClientRequestNo: "req-1", SKU: "S1",
			State: PurchaseReady, URL: "alipays://old", ExpiresAt: time.Now().Add(-time.Minute),
		},
	}}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	if response.Code != http.StatusOK {
		t.Fatalf("过期的同键点击应重新创单，得到 %d", response.Code)
	}
	if len(purchases.created) != 1 || purchases.created[0].OutRequestNo == "np_old" {
		t.Fatalf("应替换成新的请求号: %+v", purchases.created)
	}
	if purchases.byKey["req-1"].State != PurchaseReady || purchases.byKey["req-1"].URL != "alipays://platformapi/startapp?appId=1" {
		t.Fatalf("替换之后应转 ready 并带新链接: %+v", purchases.byKey["req-1"])
	}
}

// TestPurchaseWithoutClientRequestNoCreatesNewLinks 守住旧客户端：不传幂等键时不报错，
// 每次点击都按新链接处理（ADR-0074）。
func TestPurchaseWithoutClientRequestNoCreatesNewLinks(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	first := httptest.NewRecorder()
	handler.Purchase(first, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
	second := httptest.NewRecorder()
	handler.Purchase(second, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1"}`))
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("不传幂等键应照常返回链接，得到 %d 与 %d", first.Code, second.Code)
	}
	if a, b := decode[api.QuotaPurchaseLink](t, first), decode[api.QuotaPurchaseLink](t, second); a.OutRequestNo == b.OutRequestNo {
		t.Fatalf("旧客户端每次点击应是新链接: %s", a.OutRequestNo)
	}
}

// TestPurchaseStillReturnsTheLinkWhenTheRowCannotBeStored 守住写库失败不挡购买：链接
// 照常返回，只记日志（ADR-0074）。
func TestPurchaseStillReturnsTheLinkWhenTheRowCannotBeStored(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{failCreate: errors.New("pg: 写入失败")}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	response := httptest.NewRecorder()
	handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases", `{"sku_id":"S1","client_request_no":"req-1"}`))
	if response.Code != http.StatusOK {
		t.Fatalf("写库失败时仍应返回链接，得到 %d", response.Code)
	}
	if link := decode[api.QuotaPurchaseLink](t, response); link.PurchaseUrl == "" {
		t.Fatalf("应返回链接: %+v", link)
	}
}

func TestBalanceEndpointReturnsTheCurrentPoints(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodQuota: `{"code":"10000","quota_unit":"POINT","total":100,"used":40,"remaining":55}`,
	}}
	balances := &fakeBalances{}
	handler := newTestHandlerWith(newTestClient(t, caller), &fakePurchases{}, balances)
	response := httptest.NewRecorder()
	handler.Balance(response, request(http.MethodGet, "/v1/me/model-quota-purchases/quota", ""))
	balance := decode[api.QuotaBalance](t, response)
	if response.Code != http.StatusOK || balance.Remaining != 55 || balance.Total != 100 || balance.Used != 40 {
		t.Fatalf("余额应原样返回: %d %+v", response.Code, balance)
	}
	if balances.saved["user_1"] != 55 {
		t.Fatalf("刷新余额时应更新副本: %+v", balances.saved)
	}
}

// TestBalanceEndpointRejectsANonPointProduct 守住余额接口的单位校验：商品的额度单位
// 不是 POINT 时明确失败，不把数字按积分写进放行用的副本（ADR-0073）。
func TestBalanceEndpointRejectsANonPointProduct(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodQuota: `{"code":"10000","quota_unit":"COUNT","total":10,"used":3,"remaining":7}`,
	}}
	balances := &fakeBalances{}
	handler := newTestHandlerWith(newTestClient(t, caller), &fakePurchases{}, balances)
	response := httptest.NewRecorder()
	handler.Balance(response, request(http.MethodGet, "/v1/me/model-quota-purchases/quota", ""))
	if response.Code != http.StatusConflict {
		t.Fatalf("单位不是积分时应回 409，得到 %d", response.Code)
	}
	if len(balances.saved) != 0 {
		t.Fatalf("单位不是积分时不该写副本: %+v", balances.saved)
	}
}

// TestPurchaseConcurrentSameKeyCreatesOneRow 守住并发同键只落一行：锁把同一键的点击
// 串行化，后到的点击读到 ready 之后直接复用链接（ADR-0074）。
func TestPurchaseConcurrentSameKeyCreatesOneRow(t *testing.T) {
	caller := &fakeCaller{replies: map[string]string{
		methodCharge:   purchaseCapability,
		methodPurchase: purchaseReply,
	}}
	purchases := &fakePurchases{}
	handler := newTestHandler(newTestClient(t, caller), purchases)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			response := httptest.NewRecorder()
			handler.Purchase(response, request(http.MethodPost, "/v1/me/model-quota-purchases",
				`{"sku_id":"S1","client_request_no":"req-1"}`))
			if response.Code != http.StatusOK {
				t.Errorf("并发同键点击应返回链接，得到 %d", response.Code)
			}
		}()
	}
	wg.Wait()
	if len(purchases.created) != 1 {
		t.Fatalf("并发同键应只落一行，实际 %d 行", len(purchases.created))
	}
	var creates int
	for _, method := range caller.calls() {
		if method == methodPurchase {
			creates++
		}
	}
	if creates != 1 {
		t.Fatalf("并发同键应只创一次单，实际 %d 次", creates)
	}
}
