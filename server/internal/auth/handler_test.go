package auth

import (
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// testMaxJSON 是契约里普通 JSON 请求体的上限，够本包用例使用。
const testMaxJSON = 1 << 20

// api 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) PostV1AuthRegister(w http.ResponseWriter, r *http.Request) { a.h.Register(w, r) }
func (a testAPI) PostV1AuthLogin(w http.ResponseWriter, r *http.Request)    { a.h.Login(w, r) }
func (a testAPI) PostV1AuthRefresh(w http.ResponseWriter, r *http.Request)  { a.h.Refresh(w, r) }
func (a testAPI) PostV1AuthLogout(w http.ResponseWriter, r *http.Request)   { a.h.Logout(w, r) }
func (a testAPI) PostV1MeIdentitiesIdVerification(w http.ResponseWriter, r *http.Request, id string) {
	a.h.RequestIdentityVerification(w, r, id)
}
func (a testAPI) PostV1MeIdentitiesIdVerificationConfirm(w http.ResponseWriter, r *http.Request, id string) {
	a.h.ConfirmIdentityVerification(w, r, id)
}
func (a testAPI) PostV1AuthPasswordForgot(w http.ResponseWriter, r *http.Request) {
	a.h.ForgotPassword(w, r)
}
func (a testAPI) PostV1AuthPasswordReset(w http.ResponseWriter, r *http.Request) {
	a.h.ResetPassword(w, r)
}
func (a testAPI) GetV1Me(w http.ResponseWriter, r *http.Request)    { a.h.Me(w, r) }
func (a testAPI) DeleteV1Me(w http.ResponseWriter, r *http.Request) { a.h.DeleteMe(w, r) }

// newTestServer 装配本包处理器与鉴权中间件；限流在这里关掉，由 server 包统一测。
func newTestServer(t *testing.T) *testutil.Client {
	t.Helper()
	c, _ := newTestServerWithMail(t)
	return c
}

func newTestServerWithMail(t *testing.T) (*testutil.Client, *fakeMailer) {
	t.Helper()
	svc := NewService(NewMemoryStore(), time.Hour, 24*time.Hour)
	mail := &fakeMailer{}
	svc.ConfigureCodes(NewSenders(mail), []byte("test-secret"), 10*time.Minute, time.Minute)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: NewHandler(svc, log, testMaxJSON, nil, nil, nil, httpx.RemoteHost)},
		httpx.RequestID,
		Middleware(svc, log),
	)), mail
}

func TestHandlerAuthFlow(t *testing.T) {
	c := newTestServer(t)

	var p testutil.Problem
	if code := c.JSON(http.MethodGet, "/v1/me", "", nil, &p); code != http.StatusUnauthorized || p.Code != string(httpx.CodeUnauthorized) {
		t.Fatalf("anonymous /v1/me: %d %+v", code, p)
	}

	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{"identifier": "a@b.cn", "password": "password1"}, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}
	var me struct {
		Identities []struct {
			Identifier string `json:"identifier"`
			Verified   bool   `json:"verified"`
		} `json:"identities"`
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, &me); code != http.StatusOK ||
		len(me.Identities) != 1 || me.Identities[0].Identifier != "a@b.cn" || me.Identities[0].Verified {
		t.Fatalf("me: %d %+v", code, me)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{"identifier": "a@b.cn", "password": "password1"}, &p); code != http.StatusConflict || p.Code != string(httpx.CodeIdentifierTaken) {
		t.Fatalf("duplicate: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{"identifier": "a@b.cn", "password": "wrong-pass"}, &p); code != http.StatusUnauthorized || p.Code != string(httpx.CodeInvalidCredentials) {
		t.Fatalf("bad login: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]any{"identifier": "a@b.cn", "password": "password1", "extra": 1}, &p); code != http.StatusBadRequest {
		t.Fatalf("unknown field accepted: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/logout", tok.AccessToken, nil, nil); code != http.StatusNoContent {
		t.Fatalf("logout %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("token survived logout: %d", code)
	}
}

// newTestServerWithLoginLimit 装配一个失败预算只有 burst 个令牌的处理器，其他
// 限流照常关闭；令牌不补充，用例不依赖真实时钟。
func newTestServerWithLoginLimit(t *testing.T, burst int) *testutil.Client {
	t.Helper()
	svc := NewService(NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := NewHandler(svc, log, testMaxJSON, nil, nil, nil, httpx.RemoteHost)
	h.SetLoginFailLimiter(ratelimit.New(rate.Limit(0), burst, 0))
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: h},
		httpx.RequestID,
		Middleware(svc, log),
	))
}

// TestHandlerDeleteMeRequiresPassword 核对删号要先确认密码：密码错误回 401 且
// 账号仍在，密码正确才回 204 并清空账号。
func TestHandlerDeleteMeRequiresPassword(t *testing.T) {
	c := newTestServer(t)
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"identifier": "a@b.cn", "password": "password1",
	}, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}

	var p testutil.Problem
	if code := c.JSON(http.MethodDelete, "/v1/me", tok.AccessToken, map[string]string{
		"password": "wrong-password",
	}, &p); code != http.StatusUnauthorized || p.Code != string(httpx.CodeInvalidCredentials) {
		t.Fatalf("错密码删号: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusOK {
		t.Fatalf("密码错误的删号不应影响账号: %d", code)
	}
	if code := c.JSON(http.MethodDelete, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusBadRequest {
		t.Fatalf("缺请求体应回 400: %d", code)
	}

	if code := c.JSON(http.MethodDelete, "/v1/me", tok.AccessToken, map[string]string{
		"password": "password1",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("对密码删号: %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("删号之后访问令牌应失效: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{
		"identifier": "a@b.cn", "password": "password1",
	}, &p); code != http.StatusUnauthorized {
		t.Fatalf("删号之后账号应不存在: %d", code)
	}
}

// TestHandlerLoginFailBudget 核对按账号的登录失败预算：猜错一次扣一个令牌，
// 用完之后在密码校验之前就回 429，正确密码同样被挡。
func TestHandlerLoginFailBudget(t *testing.T) {
	c := newTestServerWithLoginLimit(t, 1)
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"identifier": "a@b.cn", "password": "password1",
	}, nil); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}
	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{
		"identifier": " A@B.cn ", "password": "wrong-password",
	}, &p); code != http.StatusUnauthorized {
		t.Fatalf("第一次错密码: %d %+v", code, p)
	}
	// 邮箱大小写与两端空白不同也扣同一个桶，超限之后正确密码同样被挡。
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{
		"identifier": "a@b.cn", "password": "password1",
	}, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("预算用尽应回 429: %d %+v", code, p)
	}
}

// TestHandlerDeleteMeFailBudget 核对连续输错删号密码会触发 429，且账号还在。
func TestHandlerDeleteMeFailBudget(t *testing.T) {
	c := newTestServerWithLoginLimit(t, 2)
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"identifier": "a@b.cn", "password": "password1",
	}, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}
	var p testutil.Problem
	for i := 0; i < 2; i++ {
		if code := c.JSON(http.MethodDelete, "/v1/me", tok.AccessToken, map[string]string{
			"password": "wrong-password",
		}, &p); code != http.StatusUnauthorized {
			t.Fatalf("第 %d 次错密码: %d %+v", i+1, code, p)
		}
	}
	if code := c.JSON(http.MethodDelete, "/v1/me", tok.AccessToken, map[string]string{
		"password": "password1",
	}, &p); code != http.StatusTooManyRequests || p.Code != string(httpx.CodeRateLimited) {
		t.Fatalf("预算用尽应回 429: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusOK {
		t.Fatalf("限流期间账号应当仍在: %d", code)
	}
}

// meIdentities 是 /v1/me 的测试视图：只取本文件用得到的字段。
type meIdentities struct {
	UserId     string `json:"user_id"`
	Identities []struct {
		Id         string `json:"id"`
		Kind       string `json:"kind"`
		Identifier string `json:"identifier"`
		Verified   bool   `json:"verified"`
	} `json:"identities"`
}

func TestHandlerIdentityVerificationAndPasswordReset(t *testing.T) {
	c, mail := newTestServerWithMail(t)
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"identifier": "a@b.cn", "password": "password1",
	}, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}

	var me meIdentities
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, &me); code != http.StatusOK ||
		len(me.Identities) != 1 || me.Identities[0].Kind != "email" || me.Identities[0].Verified {
		t.Fatalf("me before verification: %d %+v", code, me)
	}
	identityPath := "/v1/me/identities/" + me.Identities[0].Id + "/verification"
	if code := c.JSON(http.MethodPost, identityPath, tok.AccessToken, nil, nil); code != http.StatusNoContent {
		t.Fatalf("request code: %d", code)
	}
	codeValue := mail.lastCode(t)
	if code := c.JSON(http.MethodPost, identityPath+"/confirm", tok.AccessToken, map[string]string{
		"code": codeValue,
	}, nil); code != http.StatusNoContent {
		t.Fatalf("confirm code: %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, &me); code != http.StatusOK || !me.Identities[0].Verified {
		t.Fatalf("me after verification: %d %+v", code, me)
	}

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, identityPath+"/confirm", tok.AccessToken, map[string]string{
		"code": "000000",
	}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidCode) {
		t.Fatalf("wrong code: %d %+v", code, p)
	}
	// 别的账号名下的登录方式按不存在处理，不带出别人的联系方式。
	if code := c.JSON(http.MethodPost, "/v1/me/identities/not-mine/verification", tok.AccessToken, nil, &p); code != http.StatusNotFound || p.Code != string(httpx.CodeNotFound) {
		t.Fatalf("foreign identity: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/password/forgot", "", map[string]string{
		"identifier": "nobody@example.com",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("forgot for unknown identifier: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/password/forgot", "", map[string]string{
		"identifier": "a@b.cn",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("forgot: %d", code)
	}
	resetCode := mail.lastCode(t)
	if code := c.JSON(http.MethodPost, "/v1/auth/password/reset", "", map[string]string{
		"identifier": "a@b.cn", "code": resetCode, "new_password": "password2",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("reset: %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("old session survived reset: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{
		"identifier": "a@b.cn", "password": "password2",
	}, &tok); code != http.StatusOK {
		t.Fatalf("login with new password: %d", code)
	}
}
