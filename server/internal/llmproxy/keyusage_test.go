package llmproxy

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// TestKeyUsageShowsFailedCalls 核对失败的调用在按密钥的视图里留得下记录：一次
// 接入密钥调用被来源以 400 拒掉之后 token 记 0、额度不扣，但尝试与失败次数各加
// 一，后台因此看得见这把密钥一直在失败，而不是与没有用过的密钥一样（ADR-0083）。
func TestKeyUsageShowsFailedCalls(t *testing.T) {
	var fail atomic.Bool
	fail.Store(true)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if fail.Load() {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `{"error":{"message":"bad"}}`)
			return
		}
		fmt.Fprint(w, `{"id":"r","object":"response","output":[],"usage":{"total_tokens":9}}`)
	}))
	defer upstream.Close()

	env := newTestServer(t, baseConfig(), func(c *MemoryCatalog, box *secretbox.Box) {
		putProvider(t, c, box, "up", upstream.URL, "sk-server")
		putModel(t, c, ModelRecord{Name: "deepseek-flash", Kind: KindChat, Routes: []Route{{ProviderID: "up", UpstreamModel: "deepseek-flash"}}})
	})
	tokens, err := env.authSvc.Register(context.Background(), "fail@b.cn", "password1", "")
	if err != nil {
		t.Fatal(err)
	}
	env.quota.SetDailyLimit(tokens.UserID, 1<<30)
	principal, err := env.authSvc.Authenticate(context.Background(), tokens.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	created, apiKey, err := env.authSvc.CreateAPIKey(context.Background(), principal, "脚本")
	if err != nil {
		t.Fatal(err)
	}

	body := map[string]any{"model": "deepseek-flash", "input": []any{}}
	for range 3 {
		if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", apiKey, body, nil); code != http.StatusBadRequest {
			t.Fatalf("上游拒绝时应把 400 交给调用方，得到 %d", code)
		}
	}
	rows, err := env.quota.KeyUsage(context.Background(), "0000-01-01", "9999-12-31")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("失败的调用应留下一条按密钥的记录，得到 %d 条：%+v", len(rows), rows)
	}
	row := rows[0]
	if row.KeyID != created.ID || row.Attempts != 3 || row.Failures != 3 {
		t.Fatalf("应记 3 次尝试、3 次失败，得到 %+v", row)
	}
	if row.Tokens != 0 || row.ReservedTokens != 0 {
		t.Fatalf("失败按 0 结算，token 与预留都不应增加：%+v", row)
	}

	// 额度不被失败扣掉：恢复之后一次成功调用记 9 个 token、新增一次尝试而不增
	// 加失败，成功的那一次照常计费。
	fail.Store(false)
	if code := env.c.JSON(http.MethodPost, "/v1/llm/responses", apiKey, body, nil); code != http.StatusOK {
		t.Fatalf("恢复之后应转发成功，得到 %d", code)
	}
	rows, err = env.quota.KeyUsage(context.Background(), "0000-01-01", "9999-12-31")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("同一个账号、同一把密钥、同一天仍是一行，得到 %d 条：%+v", len(rows), rows)
	}
	if got := rows[0]; got.Tokens != 9 || got.Attempts != 4 || got.Failures != 3 || got.ReservedTokens != 0 {
		t.Fatalf("成功的那一次应计 9 个 token 且只加尝试，得到 %+v", got)
	}
}
