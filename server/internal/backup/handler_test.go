package backup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/testutil"
)

const (
	// testSchemaVersion 与服务端接受的客户端 schema 版本一致（server.ClientSchemaVersion）。
	testSchemaVersion = 27
	testMaxBytes      = 1 << 20
	testKept          = 2
)

// testAPI 只接本包的路由；其余路由由 testutil.Base 回 404。
type testAPI struct {
	testutil.Base
	h *Handler
}

func (a testAPI) GetV1Backups(w http.ResponseWriter, r *http.Request) { a.h.List(w, r) }

func (a testAPI) PostV1Backups(w http.ResponseWriter, r *http.Request, params api.PostV1BackupsParams) {
	a.h.Upload(w, r, params)
}

func (a testAPI) GetV1BackupsId(w http.ResponseWriter, r *http.Request, id string) {
	a.h.Download(w, r, id)
}

func (a testAPI) DeleteV1BackupsId(w http.ResponseWriter, r *http.Request, id string) {
	a.h.Delete(w, r, id)
}

// newTestServer 装配本包处理器与鉴权中间件，返回客户端与用于签发测试令牌的
// 账号服务。
func newTestServer(t *testing.T) (*testutil.Client, *auth.Service) {
	t.Helper()
	authSvc := auth.NewService(auth.NewMemoryStore(), time.Hour, 24*time.Hour)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewService(NewMemoryStore(), testMaxBytes, testKept, testSchemaVersion), log)
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

// upload 按契约发一份备份：请求体是 zip，头里带哈希、schema 版本与设备名；
// 调用方负责关闭响应体。
func upload(t *testing.T, c *testutil.Client, token string, data []byte, schema int) *http.Response {
	t.Helper()
	sum := sha256.Sum256(data)
	return c.Do(http.MethodPost, "/v1/backups", token, bytes.NewReader(data), map[string]string{
		"Content-Type":     "application/zip",
		"X-Content-SHA256": hex.EncodeToString(sum[:]),
		"X-Schema-Version": fmt.Sprint(schema),
		"X-Device-Name":    "PLK110",
	})
}

func TestHandlerBackupRoundTripAndRetention(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "a@b.cn")

	for i := range 3 {
		resp := upload(t, c, token, []byte(fmt.Sprintf("zip-%d", i)), testSchemaVersion)
		resp.Body.Close()
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("upload %d: %d", i, resp.StatusCode)
		}
	}
	resp := upload(t, c, token, []byte("zip"), testSchemaVersion+1)
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("other schema accepted: %d", resp.StatusCode)
	}
	resp = c.Do(http.MethodPost, "/v1/backups", token, strings.NewReader("zip"), map[string]string{
		"X-Content-SHA256": strings.Repeat("0", 64), "X-Schema-Version": fmt.Sprint(testSchemaVersion),
	})
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("hash mismatch accepted: %d", resp.StatusCode)
	}

	var list api.BackupList
	if code := c.JSON(http.MethodGet, "/v1/backups", token, nil, &list); code != http.StatusOK {
		t.Fatalf("list: %d", code)
	}
	if len(list.Backups) != 2 || list.Backups[0].DeviceName == nil || *list.Backups[0].DeviceName != "PLK110" {
		t.Fatalf("list: %+v", list)
	}
	newest := list.Backups[0]
	if newest.Id == nil {
		t.Fatal("backup id missing")
	}
	got := testutil.ReadBody(t, c.Do(http.MethodGet, "/v1/backups/"+*newest.Id, token, nil, nil))
	if string(got) != "zip-2" {
		t.Fatalf("newest backup = %q", got)
	}
}
