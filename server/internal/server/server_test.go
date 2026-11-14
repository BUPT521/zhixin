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
