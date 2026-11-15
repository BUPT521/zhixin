// Package server wires configuration, stores and handlers into one http.Handler.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
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

	authSvc := auth.NewService(st.Auth, cfg.AccessTTL, cfg.RefreshTTL)
	authSvc.OnAccountDelete(st.Sync.DeleteUser)
	authSvc.OnAccountDelete(st.Backups.DeleteUser)
	authSvc.OnAccountDelete(st.Quota.DeleteUser)

	// 路由由 api/openapi.yaml 生成：路径、方法与路径参数由生成代码约束，改了契约
	// 而这里没跟上时编译失败（ADR-0015 第 4 条）。
	var byAddr, refreshLimits *ratelimit.Limiter
	if cfg.AuthRatePerSecond > 0 {
		byAddr = ratelimit.New(rate.Limit(cfg.AuthRatePerSecond), cfg.AuthBurst, 15*time.Minute)
	}
	if cfg.RefreshRatePerSecond > 0 {
		refreshLimits = ratelimit.New(rate.Limit(cfg.RefreshRatePerSecond), cfg.RefreshBurst, 15*time.Minute)
	}
	handlers := routes{
		auth:          auth.NewHandler(authSvc, log, cfg.MaxJSONBytes, byAddr, refreshLimits),
		sync:          syncsvc.NewHandler(st.Sync, log, 16*cfg.MaxJSONBytes, ClientSchemaVersion),
		backups:       backup.NewHandler(st.Backups, log, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion),
		llm:           llmproxy.New(cfg.LLM, st.Quota, cfg.Location, log),
		schemaVersion: ClientSchemaVersion,
		ready:         st.Ready,
	}

	// 契约之外的路径给 problem 体，而不是默认的文本 404。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	})
	api.HandlerWithOptions(handlers, api.StdHTTPServerOptions{BaseRouter: mux})

	return httpx.Chain(withAuth(mux, authSvc, log),
		httpx.Recover(log),
		httpx.RequestID,
		httpx.AccessLog(log),
	)
}
