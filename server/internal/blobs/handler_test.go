package blobs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) GetV1BlobsSha256(w http.ResponseWriter, r *http.Request, sha string) {
	a.h.Get(w, r, sha)
}

func (a testAPI) HeadV1BlobsSha256(w http.ResponseWriter, r *http.Request, sha string) {
	a.h.Head(w, r, sha)
}

func (a testAPI) PutV1BlobsSha256(w http.ResponseWriter, r *http.Request, sha string) {
	a.h.Put(w, r, sha)
}

// newTestServer 装配本包处理器与鉴权中间件，返回客户端与用于签发测试令牌的
// 账号服务。maxBytes 是单个附件上限，accountBytes 是账号总量上限。
func newTestServer(t *testing.T, maxBytes, accountBytes int64) (*testutil.Client, *auth.Service) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(NewStore(objectstore.NewMemory()), maxBytes).SetAccountBytes(accountBytes), log)
	return testutil.NewClient(t, testutil.NewServer(
		testAPI{h: handler},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	)), authSvc
}

// signIn 注册一个测试账号并返回访问令牌。
func signIn(t *testing.T, svc *auth.Service, email string) string {
	t.Helper()
	tokens, err := svc.Register(context.Background(), email, "password1", "")
	if err != nil {
		t.Fatalf("register %s: %v", email, err)
	}
	return tokens.AccessToken
}

func blobSHA(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func TestHandlerBlobRoundTrip(t *testing.T) {
	c, authSvc := newTestServer(t, 1<<20, 1<<30)
	token := signIn(t, authSvc, "a@b.cn")
	data := []byte("attachment-bytes")
	sha := blobSHA(data)

	if resp := c.Do(http.MethodPut, "/v1/blobs/"+sha, token, bytes.NewReader(data), nil); resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload: %d", resp.StatusCode)
	}
	resp := c.Do(http.MethodHead, "/v1/blobs/"+sha, token, nil, nil)
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Content-Length") != fmt.Sprint(len(data)) {
		t.Fatalf("head: %d length %q", resp.StatusCode, resp.Header.Get("Content-Length"))
	}
	resp = c.Do(http.MethodGet, "/v1/blobs/"+sha, token, nil, nil)
	got := testutil.ReadBody(t, resp)
	if resp.StatusCode != http.StatusOK || !bytes.Equal(got, data) || resp.Header.Get("X-Content-SHA256") != sha {
		t.Fatalf("download: %d %q", resp.StatusCode, got)
	}

	missing := blobSHA([]byte("missing"))
	if resp := c.Do(http.MethodHead, "/v1/blobs/"+missing, token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("head missing: %d", resp.StatusCode)
	}
	var p testutil.Problem
	if code := c.JSON(http.MethodGet, "/v1/blobs/"+missing, token, nil, &p); code != http.StatusNotFound || p.Code != string(httpx.CodeNotFound) {
		t.Fatalf("get missing: %d %+v", code, p)
	}
	if code := c.JSON(http.MethodGet, "/v1/blobs/not-a-hash", token, nil, &p); code != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
		t.Fatalf("bad sha format: %d %+v", code, p)
	}

	// Attachments are scoped to the account that uploaded them.
	other := signIn(t, authSvc, "c@d.cn")
	if resp := c.Do(http.MethodHead, "/v1/blobs/"+sha, other, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("other account sees the attachment: %d", resp.StatusCode)
	}

	// The routes require a bearer token like the rest of /v1.
	if resp := c.Do(http.MethodPut, "/v1/blobs/"+sha, "", bytes.NewReader(data), nil); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous upload: %d", resp.StatusCode)
	}
}

func TestHandlerBlobRejectsHashMismatch(t *testing.T) {
	c, authSvc := newTestServer(t, 1<<20, 1<<30)
	token := signIn(t, authSvc, "a@b.cn")
	data := []byte("real-bytes")
	claimed := blobSHA([]byte("other-bytes"))

	var p testutil.Problem
	if code := c.JSON(http.MethodPut, "/v1/blobs/"+claimed, token, nil, &p); code != http.StatusBadRequest {
		t.Fatalf("empty body: %d", code)
	}
	resp := c.Do(http.MethodPut, "/v1/blobs/"+claimed, token, bytes.NewReader(data), nil)
	p = testutil.ReadProblem(t, resp)
	if resp.StatusCode != http.StatusBadRequest || p.Code != string(httpx.CodeInvalidRequest) {
		t.Fatalf("hash mismatch: %d %+v", resp.StatusCode, p)
	}
	if resp := c.Do(http.MethodHead, "/v1/blobs/"+claimed, token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("a mismatched upload must not be stored: %d", resp.StatusCode)
	}
}

// TestHandlerBlobAccountQuota 守住账号总量：同一份内容重复上传不重复计费，
// 超限时返回 413 storage_full 并在 extra 里给出 used_bytes 与 limit_bytes，
// 另一个账号不受影响。
func TestHandlerBlobAccountQuota(t *testing.T) {
	c, authSvc := newTestServer(t, 1<<20, 10)
	token := signIn(t, authSvc, "a@b.cn")
	other := signIn(t, authSvc, "c@d.cn")

	body := []byte("123456") // 6 字节
	for range 2 {
		if resp := c.Do(http.MethodPut, "/v1/blobs/"+blobSHA(body), token, bytes.NewReader(body), nil); resp.StatusCode != http.StatusCreated {
			t.Fatalf("upload of the same content: %d", resp.StatusCode)
		}
	}

	second := []byte("abcdef") // 另 6 字节，6+6 超过上限 10
	p := testutil.ReadProblem(t, c.Do(http.MethodPut, "/v1/blobs/"+blobSHA(second), token, bytes.NewReader(second), nil))
	if p.Status != http.StatusRequestEntityTooLarge || p.Code != string(httpx.CodeStorageFull) {
		t.Fatalf("over quota: %+v", p)
	}
	if p.Extra["used_bytes"] != float64(6) || p.Extra["limit_bytes"] != float64(10) {
		t.Fatalf("quota numbers: %+v", p.Extra)
	}
	// 被拒绝的内容没有落盘。
	if resp := c.Do(http.MethodHead, "/v1/blobs/"+blobSHA(second), token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("rejected upload was stored: %d", resp.StatusCode)
	}

	// 另一个账号的总量单独计算。
	if resp := c.Do(http.MethodPut, "/v1/blobs/"+blobSHA(second), other, bytes.NewReader(second), nil); resp.StatusCode != http.StatusCreated {
		t.Fatalf("another account was limited: %d", resp.StatusCode)
	}
}

// TestHandlerPutBlockedDuringPurge 守住清除期间的写拦截：gate 返回
// cloudpurge.ErrPurging 时 Put 回 409 conflict 且不落字节，读取不受影响。
func TestHandlerPutBlockedDuringPurge(t *testing.T) {
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(NewStore(objectstore.NewMemory()), 1<<20).SetAccountBytes(1<<30), log)
	handler.SetPurgeGate(func(context.Context, string) error { return cloudpurge.ErrPurging })
	c := testutil.NewClient(t, testutil.NewServer(
		testAPI{h: handler},
		httpx.RequestID,
		auth.Middleware(authSvc, log),
	))
	token := signIn(t, authSvc, "a@b.cn")
	data := []byte("blocked")

	p := testutil.ReadProblem(t, c.Do(http.MethodPut, "/v1/blobs/"+blobSHA(data), token, bytes.NewReader(data), nil))
	if p.Status != http.StatusConflict || p.Code != string(httpx.CodeConflict) {
		t.Fatalf("upload during purge: %+v", p)
	}
	if resp := c.Do(http.MethodHead, "/v1/blobs/"+blobSHA(data), token, nil, nil); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("blocked upload was stored: %d", resp.StatusCode)
	}
}

func TestHandlerBlobRejectsOversize(t *testing.T) {
	c, authSvc := newTestServer(t, 4, 1<<30)
	token := signIn(t, authSvc, "a@b.cn")
	data := []byte("too many bytes")
	p := testutil.ReadProblem(t, c.Do(http.MethodPut, "/v1/blobs/"+blobSHA(data), token, bytes.NewReader(data), nil))
	if p.Status != http.StatusRequestEntityTooLarge || p.Code != string(httpx.CodePayloadTooLarge) {
		t.Fatalf("oversize: %+v", p)
	}
}
