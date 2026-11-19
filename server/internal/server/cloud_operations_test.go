package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/auth"
)

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
	serve := func(method, path, user string, verified bool) int {
		req := httptest.NewRequest(method, path, nil)
		req.Pattern = method + " " + path
		req = req.WithContext(auth.WithPrincipal(req.Context(), auth.Principal{UserID: user, EmailVerified: verified}))
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w.Code
	}
	if status := serve(http.MethodPost, "/v1/backups", "user", false); status != http.StatusForbidden {
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
