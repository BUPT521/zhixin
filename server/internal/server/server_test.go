package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/config"
)

type harness struct {
	t   *testing.T
	srv *httptest.Server
	cfg config.Config
}

func newHarness(t *testing.T, env map[string]string) *harness {
	t.Helper()
	// 用例都从同一个来源地址发请求，默认关掉限流，免得相互干扰；
	// 专门测限流的用例自己把这些变量打开。
	merged := map[string]string{
		"ZHIXIN_AUTH_RATE":    "0",
		"ZHIXIN_REFRESH_RATE": "0",
		"ZHIXIN_UPLOAD_RATE":  "0",
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
	srv := httptest.NewServer(New(cfg, MemoryStores(), log))
	t.Cleanup(srv.Close)
	return &harness{t: t, srv: srv, cfg: cfg}
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

func (h *harness) signUp(email string) string {
	h.t.Helper()
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if code := h.json("POST", "/v1/auth/register", "", map[string]string{"email": email, "password": "password1"}, &tok); code != http.StatusCreated {
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

func TestAuthFlow(t *testing.T) {
	h := newHarness(t, nil)
	var p problem
	if code := h.json("GET", "/v1/me", "", nil, &p); code != 401 || p.Code != "unauthorized" {
		t.Fatalf("anonymous /v1/me: %d %+v", code, p)
	}
	token := h.signUp("a@b.cn")

	var me struct {
		Email string `json:"email"`
	}
	if code := h.json("GET", "/v1/me", token, nil, &me); code != 200 || me.Email != "a@b.cn" {
		t.Fatalf("me: %d %+v", code, me)
	}
	if code := h.json("POST", "/v1/auth/register", "", map[string]string{"email": "a@b.cn", "password": "password1"}, &p); code != 409 || p.Code != "email_taken" {
		t.Fatalf("duplicate: %d %+v", code, p)
	}
	if code := h.json("POST", "/v1/auth/login", "", map[string]string{"email": "a@b.cn", "password": "wrong-pass"}, &p); code != 401 || p.Code != "invalid_credentials" {
		t.Fatalf("bad login: %d %+v", code, p)
	}
	if code := h.json("POST", "/v1/auth/login", "", map[string]any{"email": "a@b.cn", "password": "password1", "extra": 1}, &p); code != 400 {
		t.Fatalf("unknown field accepted: %d", code)
	}
	if code := h.json("POST", "/v1/auth/logout", token, nil, nil); code != 204 {
		t.Fatalf("logout %d", code)
	}
	if code := h.json("GET", "/v1/me", token, nil, nil); code != 401 {
		t.Fatalf("token survived logout: %d", code)
	}
}

func commit(reqID string) map[string]any {
	return map[string]any{
		"request_id":     reqID,
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

func TestSyncIsLinearAndIdempotent(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("a@b.cn")

	var push struct {
		Head int64 `json:"head"`
	}
	if code := h.json("POST", "/v1/sync/commits", token, map[string]any{"base_seq": 0, "commits": []any{commit("r1"), commit("r2")}}, &push); code != 200 || push.Head != 2 {
		t.Fatalf("first push: %d %+v", code, push)
	}
	// Retrying the same push after a lost response is harmless.
	if code := h.json("POST", "/v1/sync/commits", token, map[string]any{"base_seq": 0, "commits": []any{commit("r1"), commit("r2")}}, &push); code != 200 || push.Head != 2 {
		t.Fatalf("replayed push: %d %+v", code, push)
	}
	// Another device pushing on a stale base must pull first.
	var p problem
	if code := h.json("POST", "/v1/sync/commits", token, map[string]any{"base_seq": 1, "commits": []any{commit("r3")}}, &p); code != 409 || p.Code != "conflict" || p.Extra["head"] != float64(2) {
		t.Fatalf("stale push: %d %+v", code, p)
	}

	var pull struct {
		Commits []struct {
			Seq       int64  `json:"seq"`
			RequestID string `json:"request_id"`
		} `json:"commits"`
		Head    int64 `json:"head"`
		HasMore bool  `json:"has_more"`
	}
	if code := h.json("GET", "/v1/sync/commits?after=0&limit=1", token, nil, &pull); code != 200 || len(pull.Commits) != 1 || !pull.HasMore || pull.Commits[0].RequestID != "r1" {
		t.Fatalf("pull page 1: %d %+v", code, pull)
	}
	if h.json("GET", "/v1/sync/commits?after=1", token, nil, &pull); len(pull.Commits) != 1 || pull.HasMore || pull.Commits[0].Seq != 2 {
		t.Fatalf("pull page 2: %+v", pull)
	}

	bad := commit("r4")
	bad["schema_version"] = ClientSchemaVersion - 1
	if code := h.json("POST", "/v1/sync/commits", token, map[string]any{"base_seq": 2, "commits": []any{bad}}, &p); code != 400 {
		t.Fatalf("old schema accepted: %d", code)
	}

	// Logs are per account.
	other := h.signUp("c@d.cn")
	if h.json("GET", "/v1/sync/commits", other, nil, &pull); len(pull.Commits) != 0 || pull.Head != 0 {
		t.Fatalf("leaked across accounts: %+v", pull)
	}
}

// TestSyncPreservesLargeIntegers 守护契约对 before/after 的声明：行内容按
// json.RawMessage 原样转发。若退回 interface{}，这里的大整数会经 float64
// 往返变成 9007199254740992。
func TestSyncPreservesLargeIntegers(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("big@b.cn")
	const big = "9007199254740993"
	body := fmt.Sprintf(`{"base_seq":0,"commits":[{
		"request_id":"big-1","device_id":"device-a","schema_version":%d,
		"actor":"user","action":"create","created_at":"2026-11-15 10:00:00",
		"changes":[{"table":"memory","row_key":"1","op":"insert","after":{"id":%s}}]}]}`,
		ClientSchemaVersion, big)
	if code := h.json("POST", "/v1/sync/commits", token, json.RawMessage(body), nil); code != http.StatusOK {
		t.Fatalf("push: %d", code)
	}

	var pulled struct {
		Commits []struct {
			Changes json.RawMessage `json:"changes"`
		} `json:"commits"`
	}
	if code := h.json("GET", "/v1/sync/commits?after=0", token, nil, &pulled); code != http.StatusOK || len(pulled.Commits) != 1 {
		t.Fatalf("pull: %d %+v", code, pulled)
	}
	if !strings.Contains(string(pulled.Commits[0].Changes), big) {
		t.Fatalf("large integer was rewritten: %s", pulled.Commits[0].Changes)
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

func TestBackupRoundTripAndRetention(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_BACKUPS_KEPT": "2"})
	token := h.signUp("a@b.cn")

	for i := range 3 {
		if resp := upload(h, token, []byte(fmt.Sprintf("zip-%d", i)), ClientSchemaVersion); resp.StatusCode != 201 {
			t.Fatalf("upload %d: %d", i, resp.StatusCode)
		}
	}
	if resp := upload(h, token, []byte("zip"), ClientSchemaVersion+1); resp.StatusCode != 400 {
		t.Fatalf("other schema accepted: %d", resp.StatusCode)
	}
	resp := h.do("POST", "/v1/backups", token, strings.NewReader("zip"), map[string]string{
		"X-Content-SHA256": strings.Repeat("0", 64), "X-Schema-Version": fmt.Sprint(ClientSchemaVersion),
	})
	if resp.StatusCode != 400 {
		t.Fatalf("hash mismatch accepted: %d", resp.StatusCode)
	}

	var list struct {
		Backups []struct {
			ID         string `json:"id"`
			DeviceName string `json:"device_name"`
		} `json:"backups"`
	}
	h.json("GET", "/v1/backups", token, nil, &list)
	if len(list.Backups) != 2 || list.Backups[0].DeviceName != "PLK110" {
		t.Fatalf("list: %+v", list)
	}
	resp = h.do("GET", "/v1/backups/"+list.Backups[0].ID, token, nil, nil)
	got, _ := io.ReadAll(resp.Body)
	if string(got) != "zip-2" {
		t.Fatalf("newest backup = %q", got)
	}

	// Deleting the account removes the backups with it.
	if code := h.json("DELETE", "/v1/me", token, nil, nil); code != 204 {
		t.Fatalf("delete account %d", code)
	}
	again := h.signUp("a@b.cn")
	h.json("GET", "/v1/backups", again, nil, &list)
	if len(list.Backups) != 0 {
		t.Fatalf("backups survived account deletion: %+v", list)
	}
}

func blobSHA(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func TestBlobRoundTrip(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("a@b.cn")
	data := []byte("attachment-bytes")
	sha := blobSHA(data)

	if resp := h.do("PUT", "/v1/blobs/"+sha, token, bytes.NewReader(data), nil); resp.StatusCode != 201 {
		t.Fatalf("upload: %d", resp.StatusCode)
	}
	resp := h.do("HEAD", "/v1/blobs/"+sha, token, nil, nil)
	if resp.StatusCode != 200 || resp.Header.Get("Content-Length") != fmt.Sprint(len(data)) {
		t.Fatalf("head: %d length %q", resp.StatusCode, resp.Header.Get("Content-Length"))
	}
	resp = h.do("GET", "/v1/blobs/"+sha, token, nil, nil)
	got, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || !bytes.Equal(got, data) || resp.Header.Get("X-Content-SHA256") != sha {
		t.Fatalf("download: %d %q", resp.StatusCode, got)
	}

	missing := blobSHA([]byte("missing"))
	if resp := h.do("HEAD", "/v1/blobs/"+missing, token, nil, nil); resp.StatusCode != 404 {
		t.Fatalf("head missing: %d", resp.StatusCode)
	}
	var p problem
	if code := h.json("GET", "/v1/blobs/"+missing, token, nil, &p); code != 404 || p.Code != "not_found" {
		t.Fatalf("get missing: %d %+v", code, p)
	}
	if code := h.json("GET", "/v1/blobs/not-a-hash", token, nil, &p); code != 400 || p.Code != "invalid_request" {
		t.Fatalf("bad sha format: %d %+v", code, p)
	}

	// Attachments are scoped to the account that uploaded them.
	other := h.signUp("c@d.cn")
	if resp := h.do("HEAD", "/v1/blobs/"+sha, other, nil, nil); resp.StatusCode != 404 {
		t.Fatalf("other account sees the attachment: %d", resp.StatusCode)
	}

	// The routes require a bearer token like the rest of /v1.
	if resp := h.do("PUT", "/v1/blobs/"+sha, "", bytes.NewReader(data), nil); resp.StatusCode != 401 {
		t.Fatalf("anonymous upload: %d", resp.StatusCode)
	}
}

func TestBlobRejectsHashMismatch(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("a@b.cn")
	data := []byte("real-bytes")
	claimed := blobSHA([]byte("other-bytes"))

	var p problem
	if code := h.json("PUT", "/v1/blobs/"+claimed, token, nil, nil); code != 400 {
		t.Fatalf("empty body: %d", code)
	}
	resp := h.do("PUT", "/v1/blobs/"+claimed, token, bytes.NewReader(data), nil)
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 400 || p.Code != "invalid_request" {
		t.Fatalf("hash mismatch: %d %+v", resp.StatusCode, p)
	}
	if resp := h.do("HEAD", "/v1/blobs/"+claimed, token, nil, nil); resp.StatusCode != 404 {
		t.Fatalf("a mismatched upload must not be stored: %d", resp.StatusCode)
	}
}

func TestBlobRejectsOversize(t *testing.T) {
	h := newHarness(t, map[string]string{"ZHIXIN_MAX_ATTACHMENT_BYTES": "4"})
	token := h.signUp("a@b.cn")
	data := []byte("too many bytes")
	var p problem
	resp := h.do("PUT", "/v1/blobs/"+blobSHA(data), token, bytes.NewReader(data), nil)
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 413 || p.Code != "payload_too_large" {
		t.Fatalf("oversize: %d %+v", resp.StatusCode, p)
	}
}

func TestLLMProxy(t *testing.T) {
	var gotAuth string
	var gotBody map[string]any
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\n")
		w.(http.Flusher).Flush()
		fmt.Fprint(w, "data: {\"choices\":[],\"usage\":{\"total_tokens\":120}}\n\n")
		fmt.Fprint(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	h := newHarness(t, map[string]string{
		"ZHIXIN_LLM_BASE_URL":     upstream.URL,
		"ZHIXIN_LLM_API_KEY":      "sk-server",
		"ZHIXIN_LLM_DAILY_TOKENS": "100",
	})
	token := h.signUp("a@b.cn")

	var p problem
	if code := h.json("POST", "/v1/llm/chat/completions", token, map[string]any{"model": "gpt-x"}, &p); code != 400 || p.Code != "model_not_allowed" {
		t.Fatalf("model check: %d %+v", code, p)
	}

	req := map[string]any{"model": "deepseek-flash", "stream": true, "messages": []any{map[string]string{"role": "user", "content": "hi"}}}
	b, _ := json.Marshal(req)
	resp := h.do("POST", "/v1/llm/chat/completions", token, bytes.NewReader(b), nil)
	stream, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || !strings.Contains(string(stream), "你") || !strings.HasSuffix(string(stream), "data: [DONE]\n\n") {
		t.Fatalf("stream: %d %q", resp.StatusCode, stream)
	}
	if gotAuth != "Bearer sk-server" {
		t.Fatalf("upstream auth = %q; the client token must not be forwarded", gotAuth)
	}
	if gotBody["model"] != "deepseek-flash" {
		t.Fatalf("body not forwarded: %+v", gotBody)
	}

	var q struct {
		Used int64 `json:"used_tokens"`
	}
	h.json("GET", "/v1/llm/quota", token, nil, &q)
	if q.Used != 120 {
		t.Fatalf("usage = %d", q.Used)
	}
	if code := h.json("POST", "/v1/llm/chat/completions", token, req, &p); code != 429 || p.Code != "quota_exceeded" {
		t.Fatalf("quota: %d %+v", code, p)
	}
}

func TestLLMProxyDisabledWithoutKey(t *testing.T) {
	h := newHarness(t, nil)
	token := h.signUp("a@b.cn")
	var p problem
	if code := h.json("POST", "/v1/llm/chat/completions", token, map[string]any{"model": "deepseek-flash"}, &p); code != 503 || p.Code != "unavailable" {
		t.Fatalf("got %d %+v", code, p)
	}
}

func TestAuthRateLimitReturns429(t *testing.T) {
	// 每秒 0.0001 个令牌、初始 1 个：第二次请求必定被拒。
	h := newHarness(t, map[string]string{
		"ZHIXIN_AUTH_RATE":  "0.0001",
		"ZHIXIN_AUTH_BURST": "1",
	})
	body := map[string]string{"email": "rate@b.cn", "password": "password1"}
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
	body := map[string]string{"email": "refresh@b.cn", "password": "password1"}
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
	handler := New(cfg, MemoryStores(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	post := func(path, address string, body any) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(mustJSON(t, body)))
		req.RemoteAddr = address
		req.Header.Set("Content-Type", "application/json")
		result := httptest.NewRecorder()
		handler.ServeHTTP(result, req)
		return result
	}
	credentials := map[string]string{"email": "devices@example.com", "password": "password1"}
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
	handler := New(cfg, MemoryStores(), slog.New(slog.NewTextHandler(&logs, nil)))
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
	handler := New(cfg, MemoryStores(), slog.New(slog.NewTextHandler(&logs, nil)))
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

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
