// Package server wires configuration, stores and handlers into one http.Handler.
package server

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
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
	Blobs   blobs.Store
	Quota   llmproxy.Quota
	// DeleteAccount removes per-account data owned outside the auth store.
	// It runs once before the account row disappears.
	DeleteAccount auth.AccountDeleter
	// Ready reports whether external dependencies are reachable; nil means always ready.
	Ready func(ctx context.Context) error
}

// MemoryStores returns in-process stores for development and tests.
func MemoryStores() Stores {
	authStore := auth.NewMemoryStore()
	syncStore := syncsvc.NewMemoryStore()
	backupStore := backup.NewMemoryStore()
	blobStore := blobs.NewStore(objectstore.NewMemory())
	quotaStore := llmproxy.NewMemoryQuota()
	return Stores{
		Auth:    authStore,
		Sync:    syncStore,
		Backups: backupStore,
		Blobs:   blobStore,
		Quota:   quotaStore,
		DeleteAccount: func(ctx context.Context, userID string) error {
			return errors.Join(
				syncStore.DeleteUser(ctx, userID),
				backupStore.DeleteUser(ctx, userID),
				blobStore.DeleteUser(ctx, userID),
				quotaStore.DeleteUser(ctx, userID),
			)
		},
	}
}

// New builds the complete handler.
func New(cfg config.Config, st Stores, log *slog.Logger) http.Handler {
	mux := http.NewServeMux()

	authSvc := auth.NewService(st.Auth, cfg.AccessTTL, cfg.RefreshTTL)
	// 账号删除只登记一次：调用方提供的清理先删对象与各包数据，auth 再删会话
	// 与账号行。失败时停在账号行之前，同一个请求可以重试。
	authSvc.SetAccountDataDeleter(st.DeleteAccount)

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
		backups:       backup.NewHandler(backup.NewService(st.Backups, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion), log),
		blobs:         blobs.NewHandler(st.Blobs, log, cfg.MaxAttachmentBytes),
		llm:           llmproxy.New(cfg.LLM, st.Quota, cfg.Location, log),
		schemaVersion: ClientSchemaVersion,
		ready:         st.Ready,
	}

	// 契约之外的路径给 problem 体，而不是默认的文本 404。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	})
	api.HandlerWithOptions(handlers, api.StdHTTPServerOptions{
		BaseRouter:       mux,
		Middlewares:      []api.MiddlewareFunc{httpx.RecordPattern},
		ErrorHandlerFunc: httpx.BindingErrorHandler,
	})

	// 顺序从外到内：先分配 request_id 并回写响应头，再记访问日志（401/429 也
	// 因此有编号并进日志），然后恢复 panic，最后鉴权。鉴权放在访问日志之内，
	// 被拒绝的请求仍然会留下一行记录。
	return httpx.Chain(withAuth(mux, authSvc, log),
		httpx.RequestID,
		httpx.AccessLog(log),
		httpx.Recover(log),
	)
}
