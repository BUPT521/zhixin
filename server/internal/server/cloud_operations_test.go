package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
)

// servePattern 用给定的注册模式调用一次中间件链，返回状态码。
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
