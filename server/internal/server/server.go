// Package server wires configuration, stores and handlers into one http.Handler.
package server

import (
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"golang.org/x/time/rate"

	"github.com/BUPT521/zhixin/server/internal/admin"
	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/release"
	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// ClientSchemaVersion is the client data schema this server accepts for
// sync commits and backups. It must equal the schema number at the top of
// docs/01; both sides move together and old versions are rejected (ADR-0002).
const ClientSchemaVersion = 27

// Stores groups every persistence dependency so main can swap the in-memory
// implementations for PostgreSQL and object storage in one place.
type Stores struct {
	Auth    auth.Store
	Sync    syncsvc.Store
	Backups backup.Store
	Blobs   blobs.Store
	Quota   llmproxy.Quota
	// Catalog 保存管理后台配置的模型来源与路由（ADR-0029）。
	Catalog llmproxy.Catalog
	// Cache 保存按账号隔离的嵌入向量缓存（ADR-0030），派生数据，清空云端数据
	// 与删号时一并删除。
	Cache     llmproxy.EmbeddingCache
	Feedback  feedback.Store
	Retention retention.Store
	// Cloud 保存云端清除的进行中标记；Objects 与备份、附件共用同一份对象
	// 存储，清除时按账号前缀兜底清理遗留对象。
	Cloud   cloudpurge.Store
	Objects objectstore.Store
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
	// 附件字节、附件配额索引与云清除兜底共用同一份内存对象存储；分两次
	// NewMemory 会让清除看不到附件对象。
	objects := objectstore.NewMemory()
	blobStore := blobs.NewStore(objects)
	quotaStore := llmproxy.NewMemoryQuota()
	cacheStore := llmproxy.NewMemoryEmbeddingCache()
	return Stores{
		Auth:      authStore,
		Sync:      syncStore,
		Backups:   backupStore,
		Blobs:     blobStore,
		Quota:     quotaStore,
		Catalog:   llmproxy.NewMemoryCatalog(),
		Cache:     cacheStore,
		Feedback:  feedback.NewMemoryStore(),
		Retention: retention.NewMemoryStore(),
		Cloud:     cloudpurge.NewMemoryStore(),
		Objects:   objects,
		DeleteAccount: DeleteAccountData(
			syncStore.DeleteUser,
			backupStore.DeleteUser,
			blobStore.DeleteUser,
			quotaStore.DeleteUser,
			cacheStore.DeleteUser,
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

// New builds the complete handler. ctx 只用于每日清理循环：会话与验证码的过期行、
// 反馈保留期都在启动时清一次，之后每天一次，进程退出时随 ctx 一起停止。
func New(ctx context.Context, cfg config.Config, st Stores, log *slog.Logger) http.Handler {
	handler, _ := Build(ctx, cfg, st, log)
	return handler
}

// Build 组装服务并返回模型路由器，供进程定期刷新路由。
func Build(ctx context.Context, cfg config.Config, st Stores, log *slog.Logger) (http.Handler, *llmproxy.Router) {
	mux := http.NewServeMux()

	authSvc := auth.NewService(st.Auth, cfg.AccessTTL, cfg.RefreshTTL)
	// 账号删除只登记一次：调用方提供的清理先删对象与各包数据，auth 再删会话
	// 与账号行。失败时停在账号行之前，同一个请求可以重试。
	authSvc.SetAccountDataDeleter(st.DeleteAccount)
	// Argon2 并发受内存预算约束；会话数有上限；重放事件只记 user_id、session_id
	// 与 request_id，不含令牌。
	authSvc.SetPasswordBudget(cfg.Argon2MemoryBudgetMiB)
	authSvc.SetMaxSessions(cfg.MaxSessionsPerUser)
	authSvc.SetSecurityLog(log)
	go authSvc.PruneLoop(ctx, st.Auth, log)

	// 路由由 api/openapi.yaml 生成：路径、方法与路径参数由生成代码约束，改了契约
	// 而这里没跟上时编译失败（ADR-0015 第 4 条）。
	//
	// 每个进程内限流器都带桶数量上限（cfg.RateLimitKeys）：按来源地址分桶的表
	// 本来会随不同地址无限增长，到上限之后先清理空闲桶、再淘汰最久未用的键。
	var byAddr, refreshLimits, uploadLimits, codeLimits, feedbackLimits, telemetryLimits *ratelimit.Limiter
	var loginFails *ratelimit.Limiter
	if cfg.AuthRatePerSecond > 0 {
		byAddr = ratelimit.New(rate.Limit(cfg.AuthRatePerSecond), cfg.AuthBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.LoginFailRatePerSecond > 0 {
		loginFails = ratelimit.New(rate.Limit(cfg.LoginFailRatePerSecond), cfg.LoginFailBurst, 15*time.Minute, cfg.RateLimitKeys)
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
	// 反馈与匿名上报除按地址限流外还有全局写入上限，换地址也刷不满表。
	var feedbackGlobal, telemetryGlobal *ratelimit.Limiter
	if cfg.FeedbackGlobalRatePerSecond > 0 {
		feedbackGlobal = ratelimit.New(rate.Limit(cfg.FeedbackGlobalRatePerSecond), cfg.FeedbackGlobalBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.TelemetryGlobalRatePerSecond > 0 {
		telemetryGlobal = ratelimit.New(rate.Limit(cfg.TelemetryGlobalRatePerSecond), cfg.TelemetryGlobalBurst, 15*time.Minute, cfg.RateLimitKeys)
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
	authSvc.SetMailLimiter(ratelimit.New(rate.Limit(4/(24*time.Hour).Seconds()), 4, 48*time.Hour, cfg.RateLimitKeys))

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

	authHandler := auth.NewHandler(authSvc, log, cfg.MaxJSONBytes, byAddr, refreshLimits, codeLimits, clientHost)
	// 登录与删号的密码失败共用一个按账号的失败预算；不配置速率时关闭。
	authHandler.SetLoginFailLimiter(loginFails)

	syncSvc := syncsvc.NewService(st.Sync, ClientSchemaVersion).SetMaxPullBytes(cfg.SyncPullMaxBytes)
	syncHandler := syncsvc.NewHandler(syncSvc, log, 16*cfg.MaxJSONBytes)

	backupHandler := backup.NewHandler(
		backup.NewService(st.Backups, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion), log)

	// 账号附件总量上限必须显式设置，否则只受单附件上限约束。
	blobSvc := blobs.NewService(st.Blobs, cfg.MaxAttachmentBytes).SetAccountBytes(cfg.MaxAccountAttachmentBytes)
	blobHandler := blobs.NewHandler(blobSvc, log)

	// 云端清除编排备份、提交序列、附件与遗留对象；清除期间三个写处理器由 gate
	// 回 409，读接口不受影响。
	purgeSvc := cloudpurge.New(st.Cloud, st.Backups, st.Sync, st.Blobs, st.Cache, st.Objects)
	syncHandler.SetPurgeGate(purgeSvc.Gate)
	backupHandler.SetPurgeGate(purgeSvc.Gate)
	blobHandler.SetPurgeGate(purgeSvc.Gate)

	// 模型来源的 key 加密入库。没有配置密钥时，内存存储用一把随进程消失的
	// 随机密钥（数据本来也随进程消失）；数据库存储则无法保存或解密 key，
	// config.Load 在打开后台时已经要求配置。
	var box *secretbox.Box
	if len(cfg.SecretKey) > 0 {
		b, err := secretbox.New(cfg.SecretKey)
		if err != nil {
			log.Error("ZHIXIN_SECRET_KEY is unusable", slog.String("error", err.Error()))
		}
		box = b
	} else if cfg.DatabaseURL == "" {
		box = secretbox.Random()
	}
	router := llmproxy.NewRouter(st.Catalog, box, llmproxy.EnvSourceFrom(cfg.LLM), log)
	if err := router.Reload(ctx); err != nil {
		log.Error("load model routes; serving env models only until the next reload", slog.String("error", err.Error()))
	}
	var adminLimits *ratelimit.Limiter
	if cfg.AdminRatePerSecond > 0 {
		adminLimits = ratelimit.New(rate.Limit(cfg.AdminRatePerSecond), cfg.AdminBurst, 15*time.Minute, cfg.RateLimitKeys)
	}

	adminGuard := admin.Middleware(admin.Options{Token: cfg.AdminToken, Limiter: adminLimits, ClientHost: clientHost})

	llmProxy := llmproxy.NewRoutedHandler(cfg.LLM, router, st.Quota, cfg.Location, log)
	// 嵌入向量缓存是派生数据：按账号隔离，命中时省掉嵌入与计费；清除云端数据
	// 期间不写，清除与删号时一并删除（ADR-0030）。
	llmProxy.SetEmbeddingCache(st.Cache)
	llmProxy.SetEmbeddingCacheGate(purgeSvc.Gate)
	llmProxy.SetConcurrencyLimit(cfg.LLM.ConcurrentPerUser)
	if cfg.LLM.RequireVerifiedEmail {
		llmProxy.SetEmailVerifier(func(ctx context.Context, _ string) (bool, error) {
			return auth.MustPrincipal(ctx).EmailVerified, nil
		})
	}

	feedbackSvc := feedback.NewService(st.Feedback)
	feedbackSvc.SetKeepDays(cfg.FeedbackKeepDays)
	feedbackHandler := feedback.NewHandler(feedbackSvc, log, cfg.MaxJSONBytes, feedbackLimits, clientHost)
	feedbackHandler.SetGlobalLimiter(feedbackGlobal)
	go feedbackSvc.PruneLoop(ctx, log)

	retentionHandler := retention.NewHandler(retentionSvc, log, cfg.MaxJSONBytes, telemetryLimits, clientHost)
	retentionHandler.SetGlobalLimiter(telemetryGlobal)

	handlers := routes{
		auth:          authHandler,
		sync:          syncHandler,
		backups:       backupHandler,
		blobs:         blobHandler,
		llm:           llmProxy,
		llmAdmin:      llmproxy.NewAdmin(llmProxy, st.Catalog, box, cfg.MaxJSONBytes),
		feedback:      feedbackHandler,
		release:       release.NewHandler(cfg.Releases),
		retention:     retentionHandler,
		cloud:         cloudpurge.NewHandler(purgeSvc, log).Purge,
		schemaVersion: ClientSchemaVersion,
		ready:         st.Ready,
	}

	// 契约之外的路径给 problem 体，而不是默认的文本 404。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	})
	admin.RegisterUI(mux, adminGuard)
	accountGuard := auth.Middleware(authSvc, log)
	// 生成代码把 Middlewares 逐个套上，列表最后一个在最外层。因此按执行顺序
	// 反过来写：运行起来依次是 记录路由 → 校验身份 → 按账号限流 → 标记可缓存
	// → 处理器。记录路由在最外层，访问日志能拿到注册模式；鉴权在限流之前，未
	// 认证的请求不会消耗账号的上传额度；限流在处理器之前，请求体落盘之前就被
	// 拦住；可缓存标记在最内层，只有真正要进处理器的公开响应才会被标记。
	api.HandlerWithOptions(handlers, api.StdHTTPServerOptions{
		BaseRouter: mux,
		Middlewares: []api.MiddlewareFunc{
			cachePublic,
			syncConcurrency(),
			temporaryUploadBudget(cfg.MaxBackupBytes, cfg.MaxAttachmentBytes),
			uploadLimit(uploadLimits),
			cloudOperations(cfg.DatabaseURL != ""),
			func(next http.Handler) http.Handler {
				account := accountGuard(next)
				management := adminGuard(next)
				return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					_, path, _ := strings.Cut(r.Pattern, " ")
					if strings.HasPrefix(path, "/admin/v1/") {
						management.ServeHTTP(w, r)
						return
					}
					account.ServeHTTP(w, r)
				})
			},
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
	), router
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
