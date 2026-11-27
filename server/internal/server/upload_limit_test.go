package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

func TestInstanceCapacityIsSharedAndReleased(t *testing.T) {
	for _, tc := range []struct {
		name          string
		middleware    api.MiddlewareFunc
		first, second string
	}{
		{"backup and attachment", temporaryUploadBudget(8, 6, 3), "POST /v1/backups", "PUT /v1/blobs/{sha256}"},
		{"sync pull and push", syncConcurrency(1), "GET /v1/sync/commits", "POST /v1/sync/commits"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var handler http.Handler
			send := func(pattern string) *httptest.ResponseRecorder {
				method, path, _ := strings.Cut(pattern, " ")
				req := httptest.NewRequest(method, path, nil)
				req.Pattern = pattern
				rec := httptest.NewRecorder()
				handler.ServeHTTP(rec, req)
				return rec
			}
			handler = tc.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Pattern == tc.first {
					// The first request still holds capacity when the second arrives.
					rejected := send(tc.second)
					var problem api.Problem
					err := json.Unmarshal(rejected.Body.Bytes(), &problem)
					if rejected.Code != http.StatusServiceUnavailable || rejected.Header().Get("Retry-After") != "" ||
						err != nil || problem.Code != httpx.CodeUnavailable {
						t.Fatalf("capacity rejection = %d %v %s", rejected.Code, rejected.Header(), rejected.Body.String())
					}
				}
				w.WriteHeader(http.StatusNoContent)
			}))
			for _, pattern := range []string{tc.first, tc.second} {
				if rec := send(pattern); rec.Code != http.StatusNoContent {
					t.Fatalf("%s = %d, want 204", pattern, rec.Code)
				}
			}
		})
	}
}
