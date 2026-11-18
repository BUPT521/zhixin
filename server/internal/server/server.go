// Package server wires configuration, stores and handlers into one http.Handler.
package server

import (
	"context"
	"crypto/rand"
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
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/release"
	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// ClientSchemaVersion is the client data schema this server accepts for
// sync commits and backups. It must equal the schema number at the top of
// docs/01; both sides move together and old versions are rejected (ADR-0002).
const ClientSchemaVersion = 27

// Stores groups every persistence dependency so main can swap the in-memory
// implementations for PostgreSQL and object storage in one place.
type Stores struct {
	Auth      auth.Store
	Sync      syncsvc.Store
	Backups   backup.Store
	Blobs     blobs.Store
	Quota     llmproxy.Quota
	Feedback  feedback.Store
	Retention retention.Store
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
		Auth:      authStore,
		Sync:      syncStore,
		Backups:   backupStore,
		Blobs:     blobStore,
		Quota:     quotaStore,
		Feedback:  feedback.NewMemoryStore(),
		Retention: retention.NewMemoryStore(),
		DeleteAccount: DeleteAccountData(
			syncStore.DeleteUser,
			backupStore.DeleteUser,
			blobStore.DeleteUser,
			quotaStore.DeleteUser,
		),
	}
}

// DeleteAccountData 把各存储的账号清理合成一次操作：auth.Service 在删除账号行
// 之前调用它，任何一步失败都返回错误，整体可以重试。内存装配与 PostgreSQL
// 装配都从这里生成，扇出只登记一次。
func DeleteAccountData(deleters ...func(ctx context.Context, userID string) error) auth.AccountDeleter {
	return func(ctx context.Context, userID string) error {
		errs := make([]error, len(deleters))
		for i, delete := range deleters {
			errs[i] = delete(ctx, userID)
		}
		return errors.Join(errs...)
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
	//
	// 每个进程内限流器都带桶数量上限（cfg.RateLimitKeys）：按来源地址分桶的表
	// 本来会随不同地址无限增长，到上限之后先清理空闲桶、再淘汰最久未用的键。
	var byAddr, refreshLimits, uploadLimits, codeLimits, feedbackLimits, telemetryLimits *ratelimit.Limiter
	if cfg.AuthRatePerSecond > 0 {
		byAddr = ratelimit.New(rate.Limit(cfg.AuthRatePerSecond), cfg.AuthBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.RefreshRatePerSecond > 0 {
		refreshLimits = ratelimit.New(rate.Limit(cfg.RefreshRatePerSecond), cfg.RefreshBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.UploadRatePerSecond > 0 {
		uploadLimits = ratelimit.New(rate.Limit(cfg.UploadRatePerSecond), cfg.UploadBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.CodeRatePerSecond > 0 {
		codeLimits = ratelimit.New(rate.Limit(cfg.CodeRatePerSecond), cfg.CodeBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.FeedbackRatePerSecond > 0 {
		feedbackLimits = ratelimit.New(rate.Limit(cfg.FeedbackRatePerSecond), cfg.FeedbackBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.TelemetryRatePerSecond > 0 {
		telemetryLimits = ratelimit.New(rate.Limit(cfg.TelemetryRatePerSecond), cfg.TelemetryBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	mailer, err := auth.NewMailer(auth.MailerConfig{
		Addr:     cfg.SMTPAddr,
		From:     cfg.SMTPFrom,
		Username: cfg.SMTPUsername,
		Password: cfg.SMTPPassword,
		TLS:      cfg.SMTPTLS,
		LogOnly:  cfg.MailLog,
	}, log)
	if err != nil {
		log.Error("mail is disabled because its configuration is invalid", slog.String("error", err.Error()))
		mailer = nil
	}
	codeSecret := []byte(cfg.CodeSecret)
	if len(codeSecret) == 0 {
		codeSecret = make([]byte, 32)
		if _, err := rand.Read(codeSecret); err != nil {
			log.Error("cannot generate a code secret", slog.String("error", err.Error()))
		}
		log.Warn("ZHIXIN_CODE_SECRET is empty: verification codes stop working after a restart")
	}
	authSvc.ConfigureCodes(mailer, codeSecret, cfg.CodeTTL, cfg.CodeCooldown)

	// 匿名活跃的安装标识用 HMAC 保存；密钥为空时每次启动随机生成，重启后同一个
	// 安装会被当成新的，留存数字偏高，因此生产必须固定。
	telemetrySecret := []byte(cfg.TelemetrySecret)
	if len(telemetrySecret) == 0 {
		telemetrySecret = make([]byte, 32)
		if _, err := rand.Read(telemetrySecret); err != nil {
			log.Error("cannot generate a telemetry secret", slog.String("error", err.Error()))
		}
		log.Warn("ZHIXIN_TELEMETRY_SECRET is empty: install hashes change on restart and active counts inflate")
	}
	retentionSvc := retention.NewService(st.Retention, telemetrySecret, cfg.Location)
	authSvc.SetActivityRecorder(retentionSvc)

	clientHost := httpx.NewClientHost(cfg.TrustedProxies)
	handlers := routes{
		auth:          auth.NewHandler(authSvc, log, cfg.MaxJSONBytes, byAddr, refreshLimits, codeLimits, clientHost),
		sync:          syncsvc.NewHandler(syncsvc.NewService(st.Sync, ClientSchemaVersion), log, 16*cfg.MaxJSONBytes),
		backups:       backup.NewHandler(backup.NewService(st.Backups, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion), log),
		blobs:         blobs.NewHandler(blobs.NewService(st.Blobs, cfg.MaxAttachmentBytes), log),
		llm:           llmproxy.NewHandler(cfg.LLM, st.Quota, cfg.Location, log),
		feedback:      feedback.NewHandler(feedback.NewService(st.Feedback), log, cfg.MaxJSONBytes, feedbackLimits, clientHost),
		release:       release.NewHandler(cfg.Releases),
		retention:     retention.NewHandler(retentionSvc, log, cfg.MaxJSONBytes, telemetryLimits, clientHost),
		schemaVersion: ClientSchemaVersion,
		ready:         st.Ready,
	}

	// 契约之外的路径给 problem 体，而不是默认的文本 404。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	})
	// 生成代码把 Middlewares 逐个套上，列表最后一个在最外层。因此按执行顺序
	// 反过来写：运行起来依次是 记录路由 → 校验身份 → 按账号限流 → 标记可缓存
	// → 处理器。记录路由在最外层，访问日志能拿到注册模式；鉴权在限流之前，未
	// 认证的请求不会消耗账号的上传额度；限流在处理器之前，请求体落盘之前就被
	// 拦住；可缓存标记在最内层，只有真正要进处理器的公开响应才会被标记。
	api.HandlerWithOptions(handlers, api.StdHTTPServerOptions{
		BaseRouter: mux,
		Middlewares: []api.MiddlewareFunc{
			cachePublic,
			uploadLimit(uploadLimits),
			auth.Middleware(authSvc, log),
			httpx.RecordPattern,
		},
		ErrorHandlerFunc: httpx.BindingErrorHandler,
	})

	// 外层顺序从外到内：先分配 request_id 并回写响应头，再记访问日志（401/404/429
	// 也因此有编号并进日志），然后统一响应头，再恢复 panic，最后是请求体读空闲
	// 期限。统一响应头在恢复 panic 之外，panic 转成的 500 也带 no-store 与
	// nosniff；鉴权与限流已经移进生成的中间件链，这里不再包一层。
	return httpx.Chain(mux,
		httpx.RequestID,
		httpx.AccessLog(log),
		httpx.SecurityHeaders,
		httpx.Recover(log),
		httpx.BodyIdleTimeout(cfg.BodyIdleTimeout),
	)
}

// cachePublic 给明确可缓存的公开响应覆盖默认的 no-store，目前只有发布清单。
// 其余响应保持默认，账号数据不会被中间层缓存。放在生成链的最内层：先鉴权、
// 再限流，只有真正要进处理器的响应才会被标记。
func cachePublic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if seconds, ok := routepolicy.CacheSeconds(r.Pattern); ok {
			httpx.Cacheable(w, seconds)
		}
		next.ServeHTTP(w, r)
	})
}
