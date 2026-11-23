package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// 本文件只测装配与横切规则：契约路由是否都接上、中间件顺序、401/404/problem
// 体、两类限流与账号删除的扇出。各模块的处理器用例在各自的包里。
type harness struct {
	t      *testing.T
	srv    *httptest.Server
	cfg    config.Config
	stores Stores
}

func newHarness(t *testing.T, env map[string]string) *harness {
	t.Helper()
	// 用例都从同一个来源地址发请求，默认关掉限流，免得相互干扰；
	// 专门测限流的用例自己把这些变量打开。
	merged := map[string]string{
		"ZHIXIN_AUTH_RATE":      "0",
		"ZHIXIN_REFRESH_RATE":   "0",
		"ZHIXIN_UPLOAD_RATE":    "0",
		"ZHIXIN_CODE_RATE":      "0",
		"ZHIXIN_FEEDBACK_RATE":  "0",
		"ZHIXIN_TELEMETRY_RATE": "0",
	}
	for k, v := range env {
		merged[k] = v
	}
	env = merged
	cfg, err := config.Load(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	stores := MemoryStores()
	srv := httptest.NewServer(New(context.Background(), cfg, stores, log))
	t.Cleanup(srv.Close)
	return &harness{t: t, srv: srv, cfg: cfg, stores: stores}
}

func (h *harness) do(method, path, token string, body io.Reader, hdr map[string]string) *http.Response {
	h.t.Helper()
	req, err := http.NewRequest(method, h.srv.URL+path, body)
	if err != nil {
		h.t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func (h *harness) json(method, path, token string, in any, out any) int {
	h.t.Helper()
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	resp := h.do(method, path, token, body, map[string]string{"Content-Type": "application/json"})
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil && err != io.EOF {
			h.t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return resp.StatusCode
}

// configureModel 通过管理接口登记一个来源与一个对外模型，让托管接口有路由
// 可用。调用方要在 newHarness 的 env 里配置 testAdminToken。
func (h *harness) configureModel(baseURL, name string) {
	h.t.Helper()
	if code := h.json("POST", "/admin/v1/providers", testAdminToken, map[string]any{
		"id": "up", "base_url": baseURL, "api_key": "test-key",
	}, nil); code != http.StatusCreated {
		h.t.Fatalf("post provider: %d", code)
	}
	if code := h.json("POST", "/admin/v1/models", testAdminToken, map[string]any{
		"name": name,
		"kind": "chat",
		"routes": []map[string]any{
			{"provider_id": "up", "upstream_model": name},
		},
	}, nil); code != http.StatusCreated {
		h.t.Fatalf("post model: %d", code)
	}
}

func (h *harness) signUp(email string) string {
	h.t.Helper()
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := h.json("POST", "/v1/auth/register", "", map[string]string{"identifier": email, "password": "password1"}, &tok); code != http.StatusCreated {
		h.t.Fatalf("register: %d", code)
	}
	return tok.AccessToken
}

type problem struct {
	Status    int            `json:"status"`
	Code      string         `json:"code"`
	RequestID string         `json:"request_id"`
	Extra     map[string]any `json:"extra"`
}

func TestHealthAndUnknownRoute(t *testing.T) {
	h := newHarness(t, nil)
	if code := h.json("GET", "/healthz", "", nil, nil); code != 200 {
		t.Fatalf("healthz %d", code)
	}
	var ready struct {
		SchemaVersion int `json:"schema_version"`
	}
	if h.json("GET", "/readyz", "", nil, &ready); ready.SchemaVersion != ClientSchemaVersion {
		t.Fatalf("readyz %+v", ready)
	}
	resp := h.do("GET", "/nope", "", nil, nil)
	var p problem
	_ = json.NewDecoder(resp.Body).Decode(&p)
	if resp.StatusCode != 404 || p.Code != "not_found" || p.RequestID == "" {
		t.Fatalf("unknown route: %d %+v", resp.StatusCode, p)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content type %q", ct)
	}
}

// TestIdentityVerificationWithoutMailer 守住没配发信时的行为：登录与备份照常，
// 验证码接口回 503，找回密码统一回 503。
func TestIdentityVerificationWithoutMailer(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("mail@example.com")

	var me struct {
		Identities []struct {
			Id       string `json:"id"`
			Kind     string `json:"kind"`
			Verified bool   `json:"verified"`
		} `json:"identities"`
	}
	if code := h.json("GET", "/v1/me", token, nil, &me); code != http.StatusOK ||
		len(me.Identities) != 1 || me.Identities[0].Kind != "email" || me.Identities[0].Verified {
		t.Fatalf("me: %d %+v", code, me)
	}
	var p problem
	if code := h.json("POST", "/v1/me/identities/"+me.Identities[0].Id+"/verification", token, nil, &p); code != http.StatusServiceUnavailable || p.Code != "unavailable" {
		t.Fatalf("request code without mail: %d %+v", code, p)
	}
	if code := h.json("POST", "/v1/auth/password/forgot", "", map[string]string{"identifier": "mail@example.com"}, nil); code != http.StatusServiceUnavailable {
		t.Fatalf("forgot without mail: %d", code)
	}
}

func upload(h *harness, token string, data []byte, schema int) *http.Response {
	sum := sha256.Sum256(data)
	return h.do("POST", "/v1/backups", token, bytes.NewReader(data), map[string]string{
		"Content-Type":     "application/zip",
		"X-Content-SHA256": hex.EncodeToString(sum[:]),
		"X-Schema-Version": fmt.Sprint(schema),
		"X-Device-Name":    "PLK110",
	})
}

// TestDeleteAccountClearsBackupBytes 守住账号删除的扇出：备份元数据与字节在
// auth 删除账号行之前清掉，重新注册同名账号看不到上一份账号的数据。
func TestDeleteAccountClearsBackupBytes(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("a@b.cn")
	if resp := upload(h, token, []byte("zip"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload: %d", resp.StatusCode)
	}

	if code := h.json("DELETE", "/v1/me", token, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("delete account %d", code)
	}
	again := h.signUp("a@b.cn")
	var list struct {
		Backups []struct {
			ID string `json:"id"`
		} `json:"backups"`
	}
	h.json("GET", "/v1/backups", again, nil, &list)
	if len(list.Backups) != 0 {
		t.Fatalf("backups survived account deletion: %+v", list)
	}
}

func blobSHA(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// commitRequest 造一条能通过契约校验的提交，用于端到端的推送与清空。
func commitRequest(requestID string) map[string]any {
	return map[string]any{
		"uid":            requestID,
		"device_id":      "device-a",
		"schema_version": ClientSchemaVersion,
		"actor":          "user",
		"action":         "create_plan_item",
		"created_at":     "2026-11-14 09:00:00",
		"changes": []map[string]any{{
			"table": "plan_item", "row_key": "01JD", "op": "insert",
			"after": map[string]any{"title": "复习第三章"},
		}},
	}
}

// TestClearCloudDataKeepsAccount 是设置页“清除云端数据（保留账号）”的端到端用例：
// 上传备份并推送提交之后调用两个 DELETE，本账号的备份列表为空、head 为 0，
// 账号仍然可用且序列从 0 重新开始，另一个账号的数据不受影响，未带令牌返回 401。
func TestClearCloudDataKeepsAccount(t *testing.T) {
	h := newHarness(t, nil)
	owner := h.signUp("clear@b.cn")
	other := h.signUp("keep@b.cn")

	push := func(token, requestID string) {
		t.Helper()
		var result struct {
			Head int64 `json:"head"`
		}
		if code := h.json("POST", "/v1/sync/commits", token, map[string]any{
			"base_seq": 0,
			"commits":  []any{commitRequest(requestID)},
		}, &result); code != http.StatusOK || result.Head != 1 {
			t.Fatalf("push %s: %d %+v", requestID, code, result)
		}
	}
	if resp := upload(h, owner, []byte("zip-owner"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("owner upload: %d", resp.StatusCode)
	}
	if resp := upload(h, other, []byte("zip-other"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("other upload: %d", resp.StatusCode)
	}
	push(owner, "r-owner")
	push(other, "r-other")

	if code := h.json("DELETE", "/v1/backups", owner, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("clear backups: %d", code)
	}
	if code := h.json("DELETE", "/v1/sync/commits", owner, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("clear commits: %d", code)
	}

	var list struct {
		Backups []struct {
			ID string `json:"id"`
		} `json:"backups"`
	}
	h.json("GET", "/v1/backups", owner, nil, &list)
	if len(list.Backups) != 0 {
		t.Fatalf("owner backups survived: %+v", list)
	}
	h.json("GET", "/v1/backups", other, nil, &list)
	if len(list.Backups) != 1 {
		t.Fatalf("other account backups changed: %+v", list)
	}

	var head struct {
		Head int64 `json:"head"`
	}
	h.json("GET", "/v1/sync/head", owner, nil, &head)
	if head.Head != 0 {
		t.Fatalf("owner head after clear: %+v", head)
	}
	h.json("GET", "/v1/sync/head", other, nil, &head)
	if head.Head != 1 {
		t.Fatalf("other account head changed: %+v", head)
	}

	// 账号本身保留，清空之后可以继续使用：再次上传备份、从 0 重新推送。
	if code := h.json("GET", "/v1/me", owner, nil, nil); code != http.StatusOK {
		t.Fatalf("account disappeared: %d", code)
	}
	if resp := upload(h, owner, []byte("zip-again"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload after clear: %d", resp.StatusCode)
	}
	push(owner, "r-again")
	if code := h.json("DELETE", "/v1/backups", owner, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("second clear backups: %d", code)
	}
	if code := h.json("DELETE", "/v1/sync/commits", owner, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("second clear commits: %d", code)
	}

	// 两个接口都要求鉴权，缺令牌时由中间件返回 401 problem。
	for _, path := range []string{"/v1/backups", "/v1/sync/commits"} {
		resp := h.do("DELETE", path, "", nil, nil)
		var p problem
		if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
			t.Fatalf("DELETE %s: decode: %v", path, err)
		}
		if resp.StatusCode != http.StatusUnauthorized || p.Code != "unauthorized" {
			t.Fatalf("DELETE %s anonymous: %d %+v", path, resp.StatusCode, p)
		}
	}
}

func TestAuthRateLimitReturns429(t *testing.T) {
	// 每秒 0.0001 个令牌、初始 1 个：第二次请求必定被拒。
	h := newHarness(t, map[string]string{
		"ZHIXIN_AUTH_RATE":  "0.0001",
		"ZHIXIN_AUTH_BURST": "1",
	})
	body := map[string]string{"identifier": "rate@b.cn", "password": "password1"}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := h.json("POST", "/v1/auth/register", "", body, &tok); code != http.StatusCreated {
		t.Fatalf("第一次注册应当通过，得到 %d", code)
	}

	resp := h.do("POST", "/v1/auth/login", "", bytes.NewReader(mustJSON(t, body)), map[string]string{"Content-Type": "application/json"})
	var p problem
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("第二次请求应返回 429，得到 %d", resp.StatusCode)
	}
	if p.Code != "rate_limited" {
		t.Fatalf("problem code 应为 rate_limited，得到 %q", p.Code)
	}
	if got := resp.Header.Get("Retry-After"); got == "" {
		t.Fatal("429 应带 Retry-After")
	}
}

func TestRefreshRateLimitReturns429(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_AUTH_RATE":     "0",
		"ZHIXIN_REFRESH_RATE":  "0.0001",
		"ZHIXIN_REFRESH_BURST": "1",
	})
	var tok struct {
		RefreshToken string `json:"refresh_token"`
	}
	body := map[string]string{"identifier": "refresh@b.cn", "password": "password1"}
	if code := h.json("POST", "/v1/auth/register", "", body, &tok); code != http.StatusCreated {
		t.Fatalf("register: %d", code)
	}

	// 第一次刷新用掉唯一的令牌并让旧令牌失效，因此第二次要用返回的新令牌；
	// 这里只关心限流，第二次无论令牌是否有效都应当先被限流拦下。
	var rotated struct {
		RefreshToken string `json:"refresh_token"`
	}
	if code := h.json("POST", "/v1/auth/refresh", "", map[string]string{"refresh_token": tok.RefreshToken}, &rotated); code != http.StatusOK {
		t.Fatalf("第一次刷新应当通过，得到 %d", code)
	}
	resp := h.do("POST", "/v1/auth/refresh", "", bytes.NewReader(mustJSON(t, map[string]string{"refresh_token": rotated.RefreshToken})), map[string]string{"Content-Type": "application/json"})
	var p problem
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.StatusCode != http.StatusTooManyRequests || p.Code != "rate_limited" {
		t.Fatalf("第二次刷新应返回 429 rate_limited，得到 %d %q", resp.StatusCode, p.Code)
	}
}

func TestRefreshRateLimitFollowsAccountAcrossDevices(t *testing.T) {
	cfg, err := config.Load(func(key string) string {
		return map[string]string{
			"ZHIXIN_REFRESH_RATE":  "0.0001",
			"ZHIXIN_REFRESH_BURST": "1",
		}[key]
	})
	if err != nil {
		t.Fatal(err)
	}
	handler := New(context.Background(), cfg, MemoryStores(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	post := func(path, address string, body any) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(mustJSON(t, body)))
		req.RemoteAddr = address
		req.Header.Set("Content-Type", "application/json")
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, req)
		return result
	}
	credentials := map[string]string{"identifier": "devices@example.com", "password": "password1"}
	first := post("/v1/auth/register", "192.0.2.1:1234", credentials)
	second := post("/v1/auth/login", "192.0.2.2:1234", credentials)
	if first.Code != http.StatusCreated || second.Code != http.StatusOK {
		t.Fatalf("register and login: %d, %d", first.Code, second.Code)
	}
	refresh := func(session *httptest.ResponseRecorder, addr string) int {
		t.Helper()
		var tokens struct {
			RefreshToken string `json:"refresh_token"`
		}
		if err := json.NewDecoder(session.Body).Decode(&tokens); err != nil {
			t.Fatal(err)
		}
		return post("/v1/auth/refresh", addr, map[string]string{"refresh_token": tokens.RefreshToken}).Code
	}
	if status := refresh(first, "192.0.2.1:1234"); status != http.StatusOK {
		t.Fatalf("first device refresh: %d", status)
	}
	if status := refresh(second, "192.0.2.2:1234"); status != http.StatusTooManyRequests {
		t.Fatalf("second device on another address: got %d, want 429", status)
	}
}

func TestAccessLogRecordsRouteAndRequestID(t *testing.T) {
	cfg, err := config.Load(func(key string) string {
		return map[string]string{"ZHIXIN_AUTH_RATE": "0", "ZHIXIN_REFRESH_RATE": "0"}[key]
	})
	if err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	handler := New(context.Background(), cfg, MemoryStores(), slog.New(slog.NewTextHandler(&logs, nil)))
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("healthz: %d", rec.Code)
	}
	requestID := rec.Header().Get("X-Request-Id")
	line := logs.String()
	for _, want := range []string{`route="GET /healthz"`, "status=200", "request_id=" + requestID} {
		if !strings.Contains(line, want) {
			t.Fatalf("access log %q does not contain %q", line, want)
		}
	}
}

func TestUnauthorizedHasRequestIDAndIsLogged(t *testing.T) {
	cfg, err := config.Load(func(key string) string {
		return map[string]string{"ZHIXIN_AUTH_RATE": "0", "ZHIXIN_REFRESH_RATE": "0"}[key]
	})
	if err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	handler := New(context.Background(), cfg, MemoryStores(), slog.New(slog.NewTextHandler(&logs, nil)))
	req := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	var p problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if rec.Code != http.StatusUnauthorized || p.RequestID == "" {
		t.Fatalf("anonymous /v1/me: %d %+v", rec.Code, p)
	}
	if got := rec.Header().Get("X-Request-Id"); got != p.RequestID {
		t.Fatalf("problem request_id %q, header %q", p.RequestID, got)
	}
	line := logs.String()
	for _, want := range []string{"status=401", "request_id=" + p.RequestID} {
		if !strings.Contains(line, want) {
			t.Fatalf("access log %q does not contain %q; a rejected request must still be logged", line, want)
		}
	}
}

// failingSyncStore 让同步存储返回错误，用来验证 500 的 problem 体、request_id
// 与日志：handler 里的 WriteInternal 是内部错误的唯一出口。
type failingSyncStore struct{}

func (failingSyncStore) State(context.Context, string) (syncsvc.State, error) {
	return syncsvc.State{}, errors.New("database is down")
}

func (failingSyncStore) Append(context.Context, string, int64, []syncsvc.Commit, syncsvc.CompactPolicy) (syncsvc.AppendResult, error) {
	return syncsvc.AppendResult{}, errors.New("database is down")
}

func (failingSyncStore) After(context.Context, string, int64, int, int64) ([]syncsvc.Commit, error) {
	return nil, errors.New("database is down")
}

func (failingSyncStore) RegisterSnapshot(context.Context, string, syncsvc.Snapshot, syncsvc.CompactPolicy) (syncsvc.State, error) {
	return syncsvc.State{}, errors.New("database is down")
}

func (failingSyncStore) Reset(context.Context, string) error {
	return errors.New("database is down")
}

func (failingSyncStore) OrphanedAttachmentsBefore(context.Context, string, time.Time) ([]string, error) {
	return nil, errors.New("database is down")
}

func (failingSyncStore) ReclaimOrphan(context.Context, string, string) error {
	return errors.New("database is down")
}

func (failingSyncStore) TouchDevice(context.Context, string, string, bool, int64) error {
	return errors.New("database is down")
}

func (failingSyncStore) EnsureDevice(context.Context, string, string) error {
	return errors.New("database is down")
}

func (failingSyncStore) AdvanceDevice(context.Context, string, string, int64, bool) error {
	return errors.New("database is down")
}

func (failingSyncStore) Devices(context.Context, string, int) ([]syncsvc.Device, error) {
	return nil, errors.New("database is down")
}

func (failingSyncStore) RenameDevice(context.Context, string, string, string) (syncsvc.Device, error) {
	return syncsvc.Device{}, errors.New("database is down")
}

func (failingSyncStore) ActiveDeviceWithoutSnapshot(context.Context, string, time.Time) (bool, error) {
	return false, errors.New("database is down")
}

func (failingSyncStore) ActiveMinSyncedSeq(context.Context, string, time.Time) (int64, bool, error) {
	return 0, false, errors.New("database is down")
}

func (failingSyncStore) Refs(context.Context, string) ([]syncsvc.Ref, error) {
	return nil, errors.New("database is down")
}

func (failingSyncStore) PutRef(context.Context, string, syncsvc.Ref) (bool, error) {
	return false, errors.New("database is down")
}

func TestInternalErrorsAreProblems(t *testing.T) {
	cfg, err := config.Load(func(key string) string {
		return map[string]string{"ZHIXIN_AUTH_RATE": "0", "ZHIXIN_REFRESH_RATE": "0"}[key]
	})
	if err != nil {
		t.Fatal(err)
	}
	stores := MemoryStores()
	stores.Sync = failingSyncStore{}
	var logs bytes.Buffer
	handler := New(context.Background(), cfg, stores, slog.New(slog.NewTextHandler(&logs, nil)))

	register := httptest.NewRequest(http.MethodPost, "/v1/auth/register",
		bytes.NewReader(mustJSON(t, map[string]string{"identifier": "fail@b.cn", "password": "password1"})))
	register.Header.Set("Content-Type", "application/json")
	registered := httptest.NewRecorder()
	handler.ServeHTTP(registered, register)
	if registered.Code != http.StatusCreated {
		t.Fatalf("register: %d", registered.Code)
	}
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(registered.Body.Bytes(), &tok); err != nil {
		t.Fatalf("decode tokens: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/sync/head", nil)
	req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	var p problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode problem: %v", err)
	}
	if rec.Code != http.StatusInternalServerError || p.Code != "internal" || p.RequestID == "" {
		t.Fatalf("store failure: %d %+v", rec.Code, p)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content type %q", ct)
	}
	if !strings.Contains(logs.String(), "request failed") {
		t.Fatalf("500 must be logged: %q", logs.String())
	}
}

func TestBindingErrorsAreProblems(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("bind@b.cn")
	cases := []struct {
		method string
		path   string
		body   io.Reader
		header map[string]string
	}{
		// Generated binding runs before the handler: a required header is missing.
		{http.MethodPost, "/v1/backups", strings.NewReader("x"), nil},
		// A header that is present but not an integer.
		{http.MethodPost, "/v1/backups", strings.NewReader("x"), map[string]string{
			"X-Content-SHA256": strings.Repeat("a", 64),
			"X-Schema-Version": "abc",
		}},
		{http.MethodGet, "/v1/sync/commits?after=abc", nil, nil},
		{http.MethodGet, "/v1/sync/commits?limit=0", nil, nil},
	}
	for _, tc := range cases {
		resp := h.do(tc.method, tc.path, token, tc.body, tc.header)
		var p problem
		if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
			t.Fatalf("%s %s: decode: %v", tc.method, tc.path, err)
		}
		if resp.StatusCode != http.StatusBadRequest || p.Code != "invalid_request" {
			t.Fatalf("%s %s: %d %+v", tc.method, tc.path, resp.StatusCode, p)
		}
		if ct := resp.Header.Get("Content-Type"); ct != "application/problem+json" {
			t.Fatalf("%s %s: content type %q", tc.method, tc.path, ct)
		}
	}
}

func TestUploadRateLimitReturns429(t *testing.T) {
	// 每秒 0.0001 个令牌、初始 1 个：第二次上传必定被拒。
	h := newHarness(t, map[string]string{
		"ZHIXIN_UPLOAD_RATE":  "0.0001",
		"ZHIXIN_UPLOAD_BURST": "1",
	})
	token := h.signUp("upload@b.cn")
	if resp := upload(h, token, []byte("first"), ClientSchemaVersion); resp.StatusCode != http.StatusCreated {
		t.Fatalf("first backup: %d", resp.StatusCode)
	}

	// Backups and attachments share one per-account bucket.
	body := []byte("attachment")
	resp := h.do("PUT", "/v1/blobs/"+blobSHA(body), token, bytes.NewReader(body), nil)
	var p problem
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.StatusCode != http.StatusTooManyRequests || p.Code != "rate_limited" {
		t.Fatalf("second upload: %d %+v", resp.StatusCode, p)
	}
	if got := resp.Header.Get("Retry-After"); got == "" {
		t.Fatal("429 must carry Retry-After")
	}
}

// TestReleaseManifestIsPublic 核对更新检查在登录之前就能读：清单从
// ZHIXIN_RELEASE_FILE 读入，接口不带令牌也返回同一个版本。
func TestReleaseManifestIsPublic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "releases.json")
	manifest := `{"releases":[{"platform":"android","version":"0.2.0","build":2,"url":"https://example.test/a.apk","sha256":"` + strings.Repeat("0", 64) + `","signature":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==","notes":"内测"}]}`
	if err := os.WriteFile(path, []byte(manifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	h := newHarness(t, map[string]string{"ZHIXIN_RELEASE_FILE": path})

	var out struct {
		Releases []struct {
			Platform string `json:"platform"`
			Version  string `json:"version"`
			Build    int64  `json:"build"`
			Url      string `json:"url"`
			Notes    string `json:"notes"`
		} `json:"releases"`
	}
	if code := h.json("GET", "/v1/app/releases", "", nil, &out); code != http.StatusOK {
		t.Fatalf("未登录也应能读发布清单，得到 %d", code)
	}
	if len(out.Releases) != 1 {
		t.Fatalf("应返回 1 条，得到 %+v", out.Releases)
	}
	got := out.Releases[0]
	if got.Platform != "android" || got.Version != "0.2.0" || got.Build != 2 || got.Url != "https://example.test/a.apk" || got.Notes != "内测" {
		t.Fatalf("清单内容不对：%+v", got)
	}
}

// TestFeedbackIsPublicAndRateLimited 核对反馈不需要登录、保存后给回执，并且
// 同一来源地址的连续提交会被限流。
func TestFeedbackIsPublicAndRateLimited(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_FEEDBACK_RATE":  "0.0001",
		"ZHIXIN_FEEDBACK_BURST": "1",
	})
	body := map[string]string{
		"content":     "记录页按“下一步”没有反应",
		"app_version": "0.2.0-dev+3",
		"platform":    "android",
	}
	var receipt struct {
		ID        string    `json:"id"`
		CreatedAt time.Time `json:"created_at"`
	}
	if code := h.json("POST", "/v1/feedback", "", body, &receipt); code != http.StatusCreated {
		t.Fatalf("未登录也应能提交反馈，得到 %d", code)
	}
	if receipt.ID == "" || receipt.CreatedAt.IsZero() {
		t.Fatalf("回执缺字段：%+v", receipt)
	}

	resp := h.do("POST", "/v1/feedback", "", bytes.NewReader(mustJSON(t, body)), map[string]string{"Content-Type": "application/json"})
	var p problem
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.StatusCode != http.StatusTooManyRequests || p.Code != "rate_limited" {
		t.Fatalf("紧接的一条应被限流，得到 %d %q", resp.StatusCode, p.Code)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Fatal("429 应带 Retry-After")
	}
}

// TestTrustedProxySplitsBucketsByForwardedFor 核对打开信任反代之后，来源地址
// 按 X-Forwarded-For 的最后一项区分：两个真实来源各有一条反馈的额度，同一个
// 来源第三次提交才会被限流。
func TestTrustedProxySplitsBucketsByForwardedFor(t *testing.T) {
	h := newHarness(t, map[string]string{
		"ZHIXIN_FEEDBACK_RATE":   "0.0001",
		"ZHIXIN_FEEDBACK_BURST":  "1",
		"ZHIXIN_TRUSTED_PROXIES": "127.0.0.1/32",
	})
	submit := func(forwardedFor string) int {
		t.Helper()
		resp := h.do("POST", "/v1/feedback", "", bytes.NewReader(mustJSON(t, map[string]string{"content": "有问题"})), map[string]string{
			"Content-Type":    "application/json",
			"X-Forwarded-For": forwardedFor,
		})
		return resp.StatusCode
	}
	if code := submit("198.51.100.1"); code != http.StatusCreated {
		t.Fatalf("第一个来源应被接受，得到 %d", code)
	}
	if code := submit("203.0.113.9"); code != http.StatusCreated {
		t.Fatalf("第二个来源应被接受，得到 %d", code)
	}
	if code := submit("198.51.100.1"); code != http.StatusTooManyRequests {
		t.Fatalf("同一个来源的第二次提交应被限流，得到 %d", code)
	}
}

// TestTelemetryIsPublicAndIdempotent 核对匿名活跃上报不需要登录、同一天重复上报
// 不报错，字段不合法时按请求错误返回。
func TestTelemetryIsPublicAndIdempotent(t *testing.T) {
	h := newHarness(t, nil)
	body := map[string]any{
		"install_id":  "0f8fad5b-d9cb-469f-a165-70867728950e",
		"app_version": "0.2.0-dev+3",
		"platform":    "android",
	}
	for i := 0; i < 2; i++ {
		if code := h.json("POST", "/v1/telemetry/active", "", body, nil); code != http.StatusNoContent {
			t.Fatalf("第 %d 次匿名上报应返回 204，得到 %d", i+1, code)
		}
	}
	if code := h.json("POST", "/v1/telemetry/active", "", map[string]any{"install_id": "short"}, nil); code != http.StatusBadRequest {
		t.Fatalf("不合法安装标识应返回 400，得到 %d", code)
	}
}

// TestQuotaOverrideIsPerAccount 核对按账号调整的额度只影响这个账号：接口返回
// 调整后的数字，另一个账号仍用配置的默认值，删号时覆盖行一并清掉。
func TestQuotaOverrideIsPerAccount(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_LLM_DAILY_TOKENS": "1000"})
	quota := h.stores.Quota.(*llmproxy.MemoryQuota)

	first := h.signUp("quota-a@b.cn")
	var me struct {
		UserID string `json:"user_id"`
	}
	h.json("GET", "/v1/me", first, nil, &me)
	quota.SetDailyLimit(me.UserID, 5000)

	var status struct {
		DailyTokens int64 `json:"daily_tokens"`
	}
	if code := h.json("GET", "/v1/llm/quota", first, nil, &status); code != http.StatusOK || status.DailyTokens != 5000 {
		t.Fatalf("调整后的额度没有生效：%d %+v", code, status)
	}
	second := h.signUp("quota-b@b.cn")
	if code := h.json("GET", "/v1/llm/quota", second, nil, &status); code != http.StatusOK || status.DailyTokens != 1000 {
		t.Fatalf("另一个账号应继续用默认额度：%d %+v", code, status)
	}

	if code := h.json("DELETE", "/v1/me", first, map[string]string{"password": "password1"}, nil); code != http.StatusNoContent {
		t.Fatalf("delete account: %d", code)
	}
	if limit, ok, err := quota.DailyLimit(context.Background(), me.UserID, llmproxy.KindChat); err != nil || ok {
		t.Fatalf("删号后覆盖行应被清掉：limit=%d ok=%v err=%v", limit, ok, err)
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
