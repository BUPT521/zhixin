package server

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// newCloudOperationsServer 用给定的注册模式调用一次中间件链，返回状态码。
func newCloudOperationsServer(handler http.Handler) func(method, path, user string, verified bool) int {
	return func(method, path, user string, verified bool) int {
		req := httptest.NewRequest(method, path, nil)
		req.Pattern = method + " " + path
		req = req.WithContext(auth.WithPrincipal(req.Context(), auth.Principal{UserID: user, ContactVerified: verified}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w.Code
	}
}

func TestCloudOperationsRequireVerificationAndKeepDeletionExclusive(t *testing.T) {
	started := make(chan struct{})
	finish := make(chan struct{})
	done := make(chan int, 1)
	handler := cloudOperations(true)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			close(started)
			<-finish
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	serve := newCloudOperationsServer(handler)
	if status := serve(http.MethodPut, "/v1/blobs/{sha256}", "user", false); status != http.StatusForbidden {
		t.Fatalf("unverified upload: %d", status)
	}
	go func() { done <- serve(http.MethodPost, "/v1/backups", "user", true) }()
	<-started
	deleting := serve(http.MethodDelete, "/v1/cloud", "user", true)
	otherAccount := serve(http.MethodDelete, "/v1/cloud", "other", true)
	close(finish)
	if status := <-done; status != http.StatusNoContent {
		t.Fatalf("active upload: %d", status)
	}
	if deleting != http.StatusConflict || otherAccount != http.StatusNoContent {
		t.Fatalf("while uploading: same account %d, other account %d", deleting, otherAccount)
	}
	if status := serve(http.MethodDelete, "/v1/cloud", "user", true); status != http.StatusNoContent {
		t.Fatalf("after upload: %d", status)
	}
}

// TestUnverifiedAccountCannotWriteCloudData 守住 S11：未确认邮箱的账号写
// PUT /v1/sync/snapshot 返回 403，不只是按上传配额的三条路由。同步快照、命名
// 版本与设备名册同样是账号的云端数据，README 与 ADR-0038 承诺整体拦截。
func TestUnverifiedAccountCannotWriteCloudData(t *testing.T) {
	handler := cloudOperations(true)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	serve := newCloudOperationsServer(handler)
	for _, route := range []struct{ method, path string }{
		{http.MethodPost, "/v1/sync/commits"},
		{http.MethodPut, "/v1/sync/snapshot"},
		{http.MethodPut, "/v1/sync/refs"},
		{http.MethodPut, "/v1/sync/devices"},
	} {
		if status := serve(route.method, route.path, "user", false); status != http.StatusForbidden {
			t.Fatalf("未验证账号 %s %s：%d，想要 403", route.method, route.path, status)
		}
		if status := serve(route.method, route.path, "user", true); status != http.StatusNoContent {
			t.Fatalf("已验证账号 %s %s：%d，想要 204", route.method, route.path, status)
		}
	}
}

// TestCloudOperationsBlockWritesDuringDeletion 守住进程内互斥覆盖的三个写入口：
// 清除进行中时快照登记、命名版本写入与改设备别名都返回 409，读请求照常；反过来
// 这三个入口进行中时，整库清除同样返回 409（审查 9.3 的 V10 删掉数据库标记之后
// 由这一层保证）。
func TestCloudOperationsBlockWritesDuringDeletion(t *testing.T) {
	blocked := make(chan struct{})
	release := make(chan struct{})
	done := make(chan int, 1)
	handler := cloudOperations(false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			close(blocked)
			<-release
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	serve := newCloudOperationsServer(handler)

	go func() { done <- serve(http.MethodDelete, "/v1/cloud", "user", true) }()
	<-blocked
	for _, path := range []string{"/v1/sync/snapshot", "/v1/sync/refs", "/v1/sync/devices"} {
		if status := serve(http.MethodPut, path, "user", true); status != http.StatusConflict {
			t.Fatalf("清除进行中写 %s: %d", path, status)
		}
	}
	if status := serve(http.MethodGet, "/v1/sync/head", "user", true); status != http.StatusNoContent {
		t.Fatalf("清除进行中读: %d", status)
	}
	close(release)
	if status := <-done; status != http.StatusNoContent {
		t.Fatalf("deletion: %d", status)
	}

	// 反过来：一个非上传写请求在途时，整库清除返回 409。
	writeStarted := make(chan struct{})
	writeRelease := make(chan struct{})
	writeDone := make(chan int, 1)
	handler = cloudOperations(false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			close(writeStarted)
			<-writeRelease
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	serve = newCloudOperationsServer(handler)
	go func() { writeDone <- serve(http.MethodPut, "/v1/sync/refs", "user", true) }()
	<-writeStarted
	if status := serve(http.MethodDelete, "/v1/cloud", "user", true); status != http.StatusConflict {
		t.Fatalf("写请求在途时的清除: %d", status)
	}
	close(writeRelease)
	if status := <-writeDone; status != http.StatusNoContent {
		t.Fatalf("naming ref: %d", status)
	}
}

// TestCloudOperationsKeepRosterWritesOut 守住会写名册的读接口与清除的互斥：清除
// 进行中 head、拉取与名册查询照常返回，但处理器被告知跳过名册更新，写入因此不会
// 落在提交序列清空之后；不写名册的读请求不带这个标记（ADR-0048、ADR-0054）。
func TestCloudOperationsKeepRosterWritesOut(t *testing.T) {
	deleting := make(chan struct{})
	release := make(chan struct{})
	done := make(chan int, 1)
	var mu sync.Mutex
	suppressed := map[string]bool{}
	handler := cloudOperations(false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		suppressed[r.Pattern] = syncsvc.RosterWriteSuppressed(r.Context())
		mu.Unlock()
		if r.Pattern == "DELETE /v1/cloud" {
			close(deleting)
			<-release
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	serve := newCloudOperationsServer(handler)

	go func() { done <- serve(http.MethodDelete, "/v1/cloud", "user", true) }()
	<-deleting
	for _, path := range []string{"/v1/sync/head", "/v1/sync/commits", "/v1/sync/devices", "/v1/me"} {
		if status := serve(http.MethodGet, path, "user", true); status != http.StatusNoContent {
			t.Fatalf("清除进行中读 %s: %d", path, status)
		}
	}
	close(release)
	if status := <-done; status != http.StatusNoContent {
		t.Fatalf("清除: %d", status)
	}

	mu.Lock()
	defer mu.Unlock()
	for _, path := range []string{"/v1/sync/head", "/v1/sync/commits", "/v1/sync/devices"} {
		if !suppressed["GET "+path] {
			t.Errorf("清除进行中的 %s 应当跳过名册更新", path)
		}
	}
	if suppressed["GET /v1/me"] {
		t.Error("/v1/me 不写名册，不应带跳过标记")
	}
}

// TestRosterReadInFlightBlocksDeletion 守住反过来的方向：一次会写名册的读请求
// 在途时，整库清除返回 409；读请求结束之后清除照常进行。
func TestRosterReadInFlightBlocksDeletion(t *testing.T) {
	reading := make(chan struct{})
	release := make(chan struct{})
	done := make(chan int, 1)
	handler := cloudOperations(false)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Pattern == "GET /v1/sync/head" {
			close(reading)
			<-release
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	serve := newCloudOperationsServer(handler)

	go func() { done <- serve(http.MethodGet, "/v1/sync/head", "user", true) }()
	<-reading
	if status := serve(http.MethodDelete, "/v1/cloud", "user", true); status != http.StatusConflict {
		t.Fatalf("名册读取在途时的清除: %d", status)
	}
	close(release)
	if status := <-done; status != http.StatusNoContent {
		t.Fatalf("读 head: %d", status)
	}
	if status := serve(http.MethodDelete, "/v1/cloud", "user", true); status != http.StatusNoContent {
		t.Fatalf("读取结束后的清除: %d", status)
	}
}

// TestUploadQuotaCoversRejectedWrites 守住限流在云端写入互斥之外：未验证账号的
// 403 也消耗一次上传额度，紧接着的合法上传返回 429，而不是悄悄放行。
func TestUploadQuotaCoversRejectedWrites(t *testing.T) {
	limiter := ratelimit.New(rate.Limit(0.0001), 1, 15*time.Minute, 10)
	handler := uploadLimit(limiter)(cloudOperations(true)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})))
	serve := newCloudOperationsServer(handler)
	if status := serve(http.MethodPost, "/v1/backups", "user", false); status != http.StatusForbidden {
		t.Fatalf("未验证的上传: %d", status)
	}
	if status := serve(http.MethodPost, "/v1/backups", "user", true); status != http.StatusTooManyRequests {
		t.Fatalf("额度用掉之后再上传: %d", status)
	}
}
