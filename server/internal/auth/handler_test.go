package auth

import (
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/httpx"
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
func (a testAPI) PostV1AuthEmailVerifyRequest(w http.ResponseWriter, r *http.Request) {
	a.h.RequestEmailVerification(w, r)
}
func (a testAPI) PostV1AuthEmailVerifyConfirm(w http.ResponseWriter, r *http.Request) {
	a.h.ConfirmEmailVerification(w, r)
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
	svc.ConfigureCodes(mail, []byte("test-secret"), 10*time.Minute, time.Minute)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: NewHandler(svc, log, testMaxJSON, nil, nil, nil)},
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
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{"email": "a@b.cn", "password": "password1"}, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}
	var me struct {
		Email string `json:"email"`
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, &me); code != http.StatusOK || me.Email != "a@b.cn" {
		t.Fatalf("me: %d %+v", code, me)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{"email": "a@b.cn", "password": "password1"}, &p); code != http.StatusConflict || p.Code != string(httpx.CodeEmailTaken) {
		t.Fatalf("duplicate: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{"email": "a@b.cn", "password": "wrong-pass"}, &p); code != http.StatusUnauthorized || p.Code != string(httpx.CodeInvalidCredentials) {
		t.Fatalf("bad login: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]any{"email": "a@b.cn", "password": "password1", "extra": 1}, &p); code != http.StatusBadRequest {
		t.Fatalf("unknown field accepted: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/logout", tok.AccessToken, nil, nil); code != http.StatusNoContent {
		t.Fatalf("logout %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("token survived logout: %d", code)
	}
}

func TestHandlerEmailVerificationAndPasswordReset(t *testing.T) {
	c, mail := newTestServerWithMail(t)
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/register", "", map[string]string{
		"email": "a@b.cn", "password": "password1",
	}, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}

	var me struct {
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, &me); code != http.StatusOK || me.EmailVerified {
		t.Fatalf("me before verification: %d %+v", code, me)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/email/verify/request", tok.AccessToken, nil, nil); code != http.StatusNoContent {
		t.Fatalf("request code: %d", code)
	}
	codeValue := mail.lastCode(t)
	if code := c.JSON(http.MethodPost, "/v1/auth/email/verify/confirm", tok.AccessToken, map[string]string{
		"code": codeValue,
	}, nil); code != http.StatusNoContent {
		t.Fatalf("confirm code: %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, &me); code != http.StatusOK || !me.EmailVerified {
		t.Fatalf("me after verification: %d %+v", code, me)
	}

	var p testutil.Problem
	if code := c.JSON(http.MethodPost, "/v1/auth/email/verify/confirm", tok.AccessToken, map[string]string{
		"code": "000000",
	}, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidCode) {
		t.Fatalf("wrong code: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/password/forgot", "", map[string]string{
		"email": "nobody@example.com",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("forgot for unknown email: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/password/forgot", "", map[string]string{
		"email": "a@b.cn",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("forgot: %d", code)
	}
	resetCode := mail.lastCode(t)
	if code := c.JSON(http.MethodPost, "/v1/auth/password/reset", "", map[string]string{
		"email": "a@b.cn", "code": resetCode, "new_password": "password2",
	}, nil); code != http.StatusNoContent {
		t.Fatalf("reset: %d", code)
	}
	if code := c.JSON(http.MethodGet, "/v1/me", tok.AccessToken, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("old session survived reset: %d", code)
	}
	if code := c.JSON(http.MethodPost, "/v1/auth/login", "", map[string]string{
		"email": "a@b.cn", "password": "password2",
	}, &tok); code != http.StatusOK {
		t.Fatalf("login with new password: %d", code)
	}
}
