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

func (a testAPI) DeleteV1Backups(w http.ResponseWriter, r *http.Request) { a.h.DeleteAll(w, r) }

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

// listBackups 返回当前账号的备份列表，调用方按契约字段判断。
func listBackups(t *testing.T, c *testutil.Client, token string) []api.Backup {
	t.Helper()
	var list api.BackupList
	if code := c.JSON(http.MethodGet, "/v1/backups", token, nil, &list); code != http.StatusOK {
		t.Fatalf("list: %d", code)
	}
	return list.Backups
}

// TestHandlerDeleteAllClearsOnlyCurrentAccount 守住“清除云端数据（保留账号）”：
// 一次删光当前账号的备份，元数据与字节都不再可读，另一个账号的备份不受影响；
// 未带令牌返回 401，重复调用保持 204。
func TestHandlerDeleteAllClearsOnlyCurrentAccount(t *testing.T) {
	c, authSvc := newTestServer(t)
	token := signIn(t, authSvc, "a@b.cn")
	other := signIn(t, authSvc, "c@d.cn")

	for _, body := range []string{"zip-1", "zip-2"} {
		resp := upload(t, c, token, []byte(body), testSchemaVersion)
		resp.Body.Close()
		if resp.StatusCode != http.StatusCreated {
			t.Fatalf("upload %s: %d", body, resp.StatusCode)
		}
	}
	items := listBackups(t, c, token)
	if len(items) != 2 || items[0].Id == nil {
		t.Fatalf("list before clear: %+v", items)
	}
	goneID := *items[0].Id

	resp := upload(t, c, other, []byte("zip-other"), testSchemaVersion)
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("other upload: %d", resp.StatusCode)
	}

	if code := c.JSON(http.MethodDelete, "/v1/backups", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("clear backups: %d", code)
	}
	if items := listBackups(t, c, token); len(items) != 0 {
		t.Fatalf("backups survived the clear: %+v", items)
	}
	// 下载按 id 找元数据，清空之后必须是 404，而不是空 zip 或 500。
	download := c.Do(http.MethodGet, "/v1/backups/"+goneID, token, nil, nil)
	download.Body.Close()
	if download.StatusCode != http.StatusNotFound {
		t.Fatalf("download after clear: %d", download.StatusCode)
	}
	// 重复调用是幂等的，客户端重试不需要区分“已经空了”。
	if code := c.JSON(http.MethodDelete, "/v1/backups", token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("second clear: %d", code)
	}

	// 另一个账号的数据按账号隔离，不受这次清空影响。
	if items := listBackups(t, c, other); len(items) != 1 {
		t.Fatalf("other account backups changed: %+v", items)
	}

	// 鉴权由中间件负责：没有令牌时处理器根本不会被调用。
	p := testutil.ReadProblem(t, c.Do(http.MethodDelete, "/v1/backups", "", nil, nil))
	if p.Status != http.StatusUnauthorized || p.Code != string(httpx.CodeUnauthorized) {
		t.Fatalf("anonymous clear: %+v", p)
	}
}
