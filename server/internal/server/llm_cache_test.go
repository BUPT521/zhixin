package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"testing"
)

// memoryHash 是客户端与缓存共同口径：UTF-8 字节的 SHA-256 小写十六进制。
func memoryHash(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// cachedVectors 是查找接口的响应；向量解成 FP16 之后核对维度。
type cachedVectors struct {
	Model      string `json:"model"`
	Dimensions *int   `json:"dimensions"`
	Vectors    []struct {
		Hash      string `json:"hash"`
		Embedding string `json:"embedding"`
	} `json:"vectors"`
}

// postEmbeddings 发一次嵌入请求，cache 决定是否带缓存请求头。
func postEmbeddings(t *testing.T, h *harness, token, model string, texts []string, cache bool) int {
	t.Helper()
	var headers map[string]string
	if cache {
		headers = map[string]string{"X-Zhixin-Embedding-Cache": "1"}
	}
	body, _ := json.Marshal(map[string]any{"model": model, "input": texts})
	resp := h.do("POST", "/v1/llm/embeddings", token, bytes.NewReader(body), headers)
	resp.Body.Close()
	return resp.StatusCode
}

func lookupVectors(t *testing.T, h *harness, token, model string, hashes []string) cachedVectors {
	t.Helper()
	var out cachedVectors
	if code := h.json("POST", "/v1/llm/embeddings/lookup", token, map[string]any{"model": model, "hashes": hashes}, &out); code != http.StatusOK {
		t.Fatalf("lookup: %d", code)
	}
	return out
}

// TestEmbeddingCacheEndToEnd 从契约路由走到缓存：带头写入，查找命中，按账号
// 隔离，清除云端数据之后缓存为空。
func TestEmbeddingCacheEndToEnd(t *testing.T) {
	provider, _ := fakeProvider(t)
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	if code := h.json("POST", "/admin/v1/providers", testAdminToken, map[string]any{
		"id": "up", "base_url": provider.URL + "/v1", "api_key": "sk",
	}, nil); code != http.StatusCreated {
		t.Fatalf("post provider: %d", code)
	}
	if code := h.json("POST", "/admin/v1/models", testAdminToken, map[string]any{
		"name":   "text-embedding-v4",
		"kind":   "embedding",
		"routes": []map[string]any{{"provider_id": "up", "upstream_model": "text-embedding-v4"}},
	}, nil); code != http.StatusCreated {
		t.Fatalf("post embedding model: %d", code)
	}
	user, userID := h.register("cache@b.cn")
	h.markContactVerified(userID)
	other, otherID := h.register("other@b.cn")
	h.markContactVerified(otherID)

	texts := []string{"第一段", "第二段"}
	hashes := []string{memoryHash(texts[0]), memoryHash(texts[1])}

	// 不带缓存请求头：嵌入照常，缓存为空。
	if code := postEmbeddings(t, h, user, "text-embedding-v4", texts, false); code != http.StatusOK {
		t.Fatalf("embeddings without cache header: %d", code)
	}
	if got := lookupVectors(t, h, user, "text-embedding-v4", hashes); len(got.Vectors) != 0 {
		t.Fatalf("不带请求头不应写缓存：%+v", got.Vectors)
	}

	// 带请求头：两条都写入，查找返回可解码的 FP16 向量。
	if code := postEmbeddings(t, h, user, "text-embedding-v4", texts, true); code != http.StatusOK {
		t.Fatalf("embeddings with cache header: %d", code)
	}
	got := lookupVectors(t, h, user, "text-embedding-v4", hashes)
	if got.Model != "text-embedding-v4" || len(got.Vectors) != 2 {
		t.Fatalf("lookup 应命中 2 条：%+v", got)
	}
	if got.Dimensions == nil || *got.Dimensions != 3 {
		t.Fatalf("模型没有配置维度时取命中行的维度：%+v", got.Dimensions)
	}
	for _, v := range got.Vectors {
		raw, err := base64.StdEncoding.DecodeString(v.Embedding)
		if err != nil || len(raw) != 6 {
			t.Fatalf("%s: FP16 base64 应为 6 字节：%v %v", v.Hash, len(raw), err)
		}
	}
	// 按账号隔离：另一个已验证的账号查不到。
	if otherGot := lookupVectors(t, h, other, "text-embedding-v4", hashes); len(otherGot.Vectors) != 0 {
		t.Fatalf("别的账号不应命中：%+v", otherGot.Vectors)
	}

	// 清除云端数据之后缓存一起清除，查找不再命中。
	resp := h.do("DELETE", "/v1/cloud", user, bytes.NewReader([]byte(`{"password":"password1"}`)),
		map[string]string{"Content-Type": "application/json"})
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("clear cloud data: %d", resp.StatusCode)
	}
	if got := lookupVectors(t, h, user, "text-embedding-v4", hashes); len(got.Vectors) != 0 {
		t.Fatalf("清除云端数据之后缓存应为空：%+v", got.Vectors)
	}
}

// TestAdminModelChangeClearsEmbeddingCache 守住 ADR-0030 第 7 条：改维度或删除
// 模型之后旧向量不再命中，同名模型再次出现时也不会读到上一个向量空间的行。
func TestAdminModelChangeClearsEmbeddingCache(t *testing.T) {
	provider, _ := fakeProvider(t)
	h := newHarness(t, map[string]string{"ZHIXIN_ADMIN_TOKEN": testAdminToken})
	admin := func(method, path string, in, out any) int {
		t.Helper()
		return h.json(method, path, testAdminToken, in, out)
	}
	resp := h.do("POST", "/admin/v1/providers", testAdminToken,
		bytes.NewReader([]byte(`{"id":"bailian","base_url":"`+provider.URL+`/v1","api_key":"sk-bailian-1234"}`)),
		map[string]string{"Content-Type": "application/json"})
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("post provider: %d", resp.StatusCode)
	}
	created := false
	putModel := func(dimensions int) {
		t.Helper()
		method, path, want := "PUT", "/admin/v1/models/emb-cache", http.StatusOK
		if !created {
			method, path, want = "POST", "/admin/v1/models", http.StatusCreated
		}
		body := map[string]any{
			"kind": "embedding", "dimensions": dimensions,
			"routes": []map[string]any{{"provider_id": "bailian", "upstream_model": "text-embedding-v4"}},
		}
		if !created {
			body["name"] = "emb-cache"
		}
		if code := admin(method, path, body, nil); code != want {
			t.Fatalf("%s %s dimensions=%d: %d", method, path, dimensions, code)
		}
		created = true
	}
	user, userID := h.register("admin-cache@b.cn")
	h.markContactVerified(userID)
	texts := []string{"改维度前"}
	hash := memoryHash(texts[0])

	putModel(3)
	if code := postEmbeddings(t, h, user, "emb-cache", texts, true); code != http.StatusOK {
		t.Fatalf("embeddings: %d", code)
	}
	if got := lookupVectors(t, h, user, "emb-cache", []string{hash}); len(got.Vectors) != 1 {
		t.Fatalf("写入之后应命中：%+v", got)
	}

	// 改维度：旧行清除，查找不再命中。
	putModel(4)
	if got := lookupVectors(t, h, user, "emb-cache", []string{hash}); len(got.Vectors) != 0 {
		t.Fatalf("改维度之后不应命中旧向量：%+v", got.Vectors)
	}

	// 重新写入之后删除模型：同名模型再建出来也读不到旧行。
	putModel(3)
	if code := postEmbeddings(t, h, user, "emb-cache", texts, true); code != http.StatusOK {
		t.Fatalf("embeddings after dimension change: %d", code)
	}
	if got := lookupVectors(t, h, user, "emb-cache", []string{hash}); len(got.Vectors) != 1 {
		t.Fatalf("重新写入之后应命中：%+v", got)
	}
	if code := admin("DELETE", "/admin/v1/models/emb-cache", nil, nil); code != http.StatusNoContent {
		t.Fatalf("delete model: %d", code)
	}
	created = false
	putModel(3)
	if got := lookupVectors(t, h, user, "emb-cache", []string{hash}); len(got.Vectors) != 0 {
		t.Fatalf("删除模型时应清掉缓存：%+v", got.Vectors)
	}
}
