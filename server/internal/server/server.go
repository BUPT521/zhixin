// Package server wires configuration, stores and handlers into one http.Handler.
package server

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// ClientSchemaVersion is the client data schema this server accepts for
// sync commits and backups. It must equal the schema number at the top of
// docs/01; both sides move together and old versions are rejected (ADR-0002).
const ClientSchemaVersion = 26

// Stores groups every persistence dependency so main can swap the in-memory
// implementations for PostgreSQL and object storage in one place.
type Stores struct {
	Auth    auth.Store
	Sync    syncsvc.Store
	Backups backup.Store
	Quota   llmproxy.Quota
	// Ready reports whether external dependencies are reachable; nil means always ready.
	Ready func(ctx context.Context) error
}

// MemoryStores returns in-process stores for development and tests.
func MemoryStores() Stores {
	return Stores{
		Auth:    auth.NewMemoryStore(),
		Sync:    syncsvc.NewMemoryStore(),
		Backups: backup.NewMemoryStore(),
		Quota:   llmproxy.NewMemoryQuota(),
	}
}

// New builds the complete handler.
func New(cfg config.Config, st Stores, log *slog.Logger) http.Handler {
	mux := http.NewServeMux()
	legacy := http.NewServeMux()

	authSvc := auth.NewService(st.Auth, cfg.AccessTTL, cfg.RefreshTTL)
	authSvc.OnAccountDelete(st.Sync.DeleteUser)
	authSvc.OnAccountDelete(st.Backups.DeleteUser)
	authSvc.OnAccountDelete(st.Quota.DeleteUser)

	legacy.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if st.Ready != nil {
			if err := st.Ready(r.Context()); err != nil {
				httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "a dependency is not reachable")
				return
			}
		}
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "ready", "schema_version": ClientSchemaVersion})
	})

	auth.NewHandler(authSvc, log, cfg.MaxJSONBytes).Register(legacy)
	// Push bodies carry row snapshots, so they get a larger cap than ordinary JSON.
	syncsvc.NewHandler(st.Sync, log, 16*cfg.MaxJSONBytes, ClientSchemaVersion).Register(legacy, authSvc.Require)
	backup.NewHandler(st.Backups, log, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion).Register(legacy, authSvc.Require)
	llmproxy.New(cfg.LLM, st.Quota, cfg.Location, log).Register(legacy, authSvc.Require)

	contractHandler(mux, legacy, cfg.MaxJSONBytes, cfg.LLM.MaxRequestBytes)

	// Anything outside the contract gets a problem body, not the default text 404.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	})

	return httpx.Chain(mux,
		httpx.Recover(log),
		httpx.RequestID,
		httpx.AccessLog(log),
	)
}
