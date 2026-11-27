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

	"github.com/BUPT521/zhixin/server/internal/accountadmin"
	"github.com/BUPT521/zhixin/server/internal/admin"
	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/config"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/feedbackadmin"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/nowpay"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/ratelimit"
	"github.com/BUPT521/zhixin/server/internal/release"
	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/retentionadmin"
	"github.com/BUPT521/zhixin/server/internal/routepolicy"
	"github.com/BUPT521/zhixin/server/internal/store/pg"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// ClientSchemaVersion is the client data schema this server accepts for
// sync commits and backups. It must equal the schema number at the top of
// docs/01; both sides move together and old versions are rejected (ADR-0002).
const ClientSchemaVersion = 33

// RetentionStore 既写入活跃数据（公开上报与鉴权中间件），也读取管理后台的
// 留存视图。PostgreSQL 与内存两种实现都满足，装配处因此不用做类型断言。
type RetentionStore interface {
	retention.Store
	retention.Reader
}

// Stores groups every persistence dependency so main can swap the in-memory
// implementations for PostgreSQL and object storage in one place.
type Stores struct {
	Auth     auth.Store
	Sync     syncsvc.Store
	Backups  backup.Store
	Blobs    blobs.Store
	Quota    llmproxy.QuotaStore
	Usage    llmproxy.UsageStore
	payments *nowpay.Handler
	// Catalog 保存管理后台配置的模型来源与路由（ADR-0029）。
	Catalog llmproxy.Catalog
	// Cache 保存按账号隔离的嵌入向量缓存（ADR-0030），派生数据，清空云端数据
	// 与删号时一并删除。
	Cache     llmproxy.EmbeddingCache
	Feedback  feedback.Repository
	Retention RetentionStore
	// Objects 与备份、附件共用同一份对象存储，清除云端数据时按账号前缀兜底
	// 清理遗留对象。
	Objects objectstore.Store
	// DeleteAccount removes per-account data owned outside the auth store.
	// It runs once before the account row disappears.
	DeleteAccount auth.AccountDeleter
	// Ready reports whether external dependencies are reachable.
	Ready func(ctx context.Context) error
}

// MemoryStores returns in-process stores for development and tests.
func MemoryStores(cfg config.Config, log *slog.Logger) Stores {
	authStore := auth.NewMemoryStore()
	syncStore := syncsvc.NewMemoryStore()
	backupStore := backup.NewMemoryStore()
	// 附件字节、附件配额索引与云清除兜底共用同一份内存对象存储；分两次
	// NewMemory 会让清除看不到附件对象。
	objects := objectstore.NewMemory()
	blobStore := blobs.NewStore(objects)
	quotaStore := llmproxy.NewMemoryQuota()
	quotaStore.SetKeyLookup(authStore.KeysByUser)
	cacheStore := llmproxy.NewMemoryEmbeddingCache()
	return Stores{
		Auth:      authStore,
		Sync:      syncStore,
		Backups:   backupStore,
		Blobs:     blobStore,
		Quota:     quotaStore,
		Usage:     llmproxy.NewMemoryUsage(),
		payments:  nowpay.NewDisabledHandler(log, cfg.RateLimitKeys, cfg.LLM.TokensPerPoint),
		Catalog:   llmproxy.NewMemoryCatalog(),
		Cache:     cacheStore,
		Feedback:  feedback.NewMemoryStore(),
		Retention: retention.NewMemoryStore(),
		Objects:   objects,
		DeleteAccount: DeleteAccountData(
			syncStore.DeleteUser,
			backupStore.DeleteUser,
			blobStore.DeleteUser,
			quotaStore.DeleteUser,
			cacheStore.DeleteUser,
		),
		Ready: func(context.Context) error { return nil },
	}
}

// ProductionStores assembles PostgreSQL, shared object storage and the payment
// handler. An enabled product always uses PostgreSQL for purchases and balances.
func ProductionStores(ctx context.Context, cfg config.Config, db *pg.Store, objects objectstore.Store, client *nowpay.Client, log *slog.Logger) (Stores, error) {
	if db == nil || objects == nil {
		return Stores{}, errors.New("production stores require PostgreSQL and object storage")
	}
	if (cfg.NowPay != nil) != (client != nil) {
		return Stores{}, errors.New("ZHIXIN_NOWPAY_PRODUCT_ID and the NowPay client must be configured together")
	}
	var payments *nowpay.Handler
	if cfg.NowPay != nil {
		checkCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
		if err := db.CheckNowPaySchema(checkCtx); err != nil {
			return Stores{}, err
		}
		payments = nowpay.NewHandler(client, db, db, cfg.NowPay.CallbackURL, log, cfg.RateLimitKeys, cfg.LLM.TokensPerPoint)
	} else {
		payments = nowpay.NewDisabledHandler(log, cfg.RateLimitKeys, cfg.LLM.TokensPerPoint)
	}
	// PostgreSQL owns metadata, while backups and attachments share the object
	// store for their bytes. Account deletion must remove those objects too.
	blobStore := pg.NewBlobStore(db)
	return Stores{
		Auth:          db,
		Sync:          db,
		Backups:       db,
		Blobs:         blobStore,
		Quota:         db,
		Usage:         db,
		payments:      payments,
		Catalog:       db,
		Cache:         pg.NewEmbeddingCache(db),
		Feedback:      db,
		Retention:     db,
		Objects:       objects,
		DeleteAccount: DeleteAccountData(db.DeleteUserObjects, blobStore.DeleteUser),
		Ready: func(ctx context.Context) error {
			if err := db.Ping(ctx); err != nil {
				return err
			}
			return objects.Ping(ctx)
		},
	}, nil
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

// Build 组装服务，返回完整的处理器。ctx 用于随进程退出的周期任务：会话与
// 验证码的过期行、反馈保留期、备份与附件对象对账都在启动时先跑一次，之后按
// 各自周期重跑，进程退出时随 ctx 一起停止。
//
// 模型路由快照只在启动时读一次，之后由管理后台保存配置时整体换新（ADR-0029）；
// 直接改库或多实例部署的修改要经后台保存一次或重启本进程才会生效。
func Build(ctx context.Context, cfg config.Config, st Stores, log *slog.Logger) (http.Handler, error) {
	return build(ctx, cfg, st, log, false)
}

// BuildModelSetup serves the management UI and API for initial setup and key
// repair. The command must serve this handler on a loopback listener.
func BuildModelSetup(ctx context.Context, cfg config.Config, st Stores, log *slog.Logger) (http.Handler, error) {
	if cfg.AdminToken == "" {
		return nil, errors.New("ZHIXIN_ADMIN_TOKEN is required for configure-models")
	}
	handler, err := build(ctx, cfg, st, log, true)
	if err != nil {
		return nil, err
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !admin.IsAdminPath(r) {
			http.NotFound(w, r)
			return
		}
		handler.ServeHTTP(w, r)
	}), nil
}

func build(ctx context.Context, cfg config.Config, st Stores, log *slog.Logger, setup bool) (http.Handler, error) {
	if cfg.NowPay != nil && cfg.DatabaseURL == "" {
		return nil, errors.New("ZHIXIN_NOWPAY_PRODUCT_ID requires PostgreSQL")
	}
	startup, err := prepareStartup(ctx, cfg, st.Catalog, log, rand.Reader, setup)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()

	authSvc := auth.NewService(st.Auth, cfg.AccessTTL, cfg.RefreshTTL)
	// 账号删除只登记一次：调用方提供的清理先删对象与各包数据，auth 再删会话
	// 与账号行。失败时停在账号行之前，同一个请求可以重试。
	authSvc.SetAccountDataDeleter(st.DeleteAccount)
	// Argon2 并发受内存预算约束；会话数有上限；重放事件只记 user_id、session_id
	// 与 request_id，不含令牌。
	authSvc.SetPasswordBudget(cfg.Argon2MemoryBudgetMiB)
	authSvc.SetMaxSessions(cfg.MaxSessionsPerUser)
	// 没有任何一种已验证登录方式的账号按保留期删除，由 PruneLoop 的每日清理执行
	// （ADR-0037）；必须在 PruneLoop 之前设置，因为它在启动时就会先清一次。
	authSvc.SetUnverifiedKeep(cfg.UnverifiedKeepDays)
	// 内测期间注册只接受配置的邮箱后缀（ADR-0085）；空清单表示不限制，装配处
	// 不再额外判断，服务层按清单精确匹配。
	authSvc.SetRegisterEmailDomains(cfg.RegisterEmailDomains)
	if len(cfg.RegisterEmailDomains) > 0 {
		log.Info("registration is limited to email domains",
			slog.String("domains", strings.Join(cfg.RegisterEmailDomains, ",")))
	}
	authSvc.SetSecurityLog(log)

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
	// 注册也是公开入口，除按来源地址的桶之外再有一层实例级上限：未确认邮箱的
	// 账号同样会占着邮箱与账号行（ADR-0037）。
	var registerGlobal *ratelimit.Limiter
	if cfg.RegisterGlobalRatePerSecond > 0 {
		registerGlobal = ratelimit.New(rate.Limit(cfg.RegisterGlobalRatePerSecond), cfg.RegisterGlobalBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.FeedbackGlobalRatePerSecond > 0 {
		feedbackGlobal = ratelimit.New(rate.Limit(cfg.FeedbackGlobalRatePerSecond), cfg.FeedbackGlobalBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	if cfg.TelemetryGlobalRatePerSecond > 0 {
		telemetryGlobal = ratelimit.New(rate.Limit(cfg.TelemetryGlobalRatePerSecond), cfg.TelemetryGlobalBurst, 15*time.Minute, cfg.RateLimitKeys)
	}
	// 发信按登录方式分发：现在只有邮箱走 SMTP，手机号与微信没有对应发送方时
	// 请求返回 501（ADR-0038）。
	authSvc.ConfigureCodes(auth.NewSenders(startup.mailer), startup.codeSecret, cfg.CodeTTL, cfg.CodeCooldown)
	// 收信预算的键是 kind:identifier：同一地址每 24 小时补充 4 枚，最多积存 4 枚。
	authSvc.SetSendLimiter(ratelimit.New(rate.Limit(4/(24*time.Hour).Seconds()), 4, 48*time.Hour, cfg.RateLimitKeys))
	// 实例级的发信总量：换地址与换收件地址都绕不过去，给 SMTP 服务商的配额兜底。
	authSvc.SetGlobalSendLimiter(ratelimit.NewGlobal(ratelimit.Limit{
		PerSecond: cfg.MailGlobalRatePerSecond,
		Burst:     cfg.MailGlobalBurst,
	}))

	retentionSvc := retention.NewService(st.Retention, startup.telemetrySecret, cfg.Location)
	authSvc.SetActivityRecorder(retentionSvc)
	// 后台的留存视图与写入共用同一份存储，时区也共用，读出来的自然日因此与
	// 写入时落库的日子一致。
	retentionReporter := retention.NewReporter(st.Retention, cfg.Location)

	clientHost := httpx.NewClientHost(cfg.TrustedProxies)

	authHandler := auth.NewHandler(authSvc, log, cfg.MaxJSONBytes, byAddr, refreshLimits, codeLimits, clientHost)
	// 登录与删号的密码失败共用一个按账号的失败预算；不配置速率时关闭。
	authHandler.SetLoginFailLimiter(loginFails)
	// 注册的实例级上限与按地址的桶同时生效；没有配置时传 nil，处理器内部换成
	// 一律放行的实现（ADR-0037）。
	authHandler.SetRegisterGlobalLimiter(registerGlobal)

	syncSvc := syncsvc.NewService(st.Sync, ClientSchemaVersion).
		SetMaxPullBytes(cfg.SyncPullMaxBytes).
		SetCompactKeep(cfg.SyncCompactKeep).
		SetCompact(cfg.SyncCompact).
		SetSnapshotGrace(cfg.SyncSnapshotGrace).
		SetDeviceActive(cfg.SyncDeviceActive).
		SetLogger(log).
		SetSnapshotBytes(cfg.MaxAttachmentBytes)
	syncHandler := syncsvc.NewHandler(syncSvc, log, 16*cfg.MaxJSONBytes)

	// 备份的元数据与字节分两步写，中断会留下没有元数据的对象：按周期对账一次，
	// 删掉库里查不到、且写于一小时之前的遗留字节（ADR-0037）。attachments/ 与
	// backups/ 共用这份对象存储，附件侧同样按 attachment 表对账。
	backupSvc := backup.NewService(st.Backups, st.Objects, st.Blobs, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion)
	backupSvc.SetReconcileInterval(cfg.BackupReconcileInterval)
	backupHandler := backup.NewHandler(backupSvc, log)

	// 账号附件总量上限必须显式设置，否则只受单附件上限约束。
	blobSvc := blobs.NewService(st.Blobs, cfg.MaxAttachmentBytes).SetAccountBytes(cfg.MaxAccountAttachmentBytes)
	blobHandler := blobs.NewHandler(st.Blobs, blobSvc, log)
	// 快照登记要核对“这个哈希是这个账号的附件”，查询由附件存储提供；没有装配时
	// 登记接口返回 501，不静默接受一个查不到归属的哈希（ADR-0043）。
	syncSvc.SetAttachments(syncAttachments{store: st.Blobs})

	// 云端清除编排备份、提交序列、附件与遗留对象；清除与写请求的互斥、清除
	// 期间写请求的 409 由进程内的 cloudOperations 中间件保证（审查 9.3 的 V10）。
	purgeSvc := cloudpurge.New(st.Backups, st.Sync, st.Blobs, st.Cache, st.Objects)

	var adminLimits *ratelimit.Limiter
	if cfg.AdminRatePerSecond > 0 {
		adminLimits = ratelimit.New(rate.Limit(cfg.AdminRatePerSecond), cfg.AdminBurst, 15*time.Minute, cfg.RateLimitKeys)
	}

	adminGuard := admin.Middleware(admin.Options{Token: cfg.AdminToken, Limiter: adminLimits, ClientHost: clientHost})

	llmProxy := llmproxy.NewRoutedHandler(cfg.LLM, startup.router, st.Quota, st.Quota, cfg.Location, log)
	llmProxy.SetUsageStore(st.Usage)
	// 嵌入向量缓存是派生数据：按账号隔离，命中时省掉嵌入与计费；清除云端数据
	// 期间不写，清除与删号时一并删除（ADR-0030）。
	llmProxy.SetEmbeddingCache(st.Cache)
	llmProxy.SetConcurrencyLimit(cfg.LLM.ConcurrentPerUser)
	if cfg.LLM.RequireVerifiedContact {
		llmProxy.SetContactVerifier(func(ctx context.Context, _ string) (bool, error) {
			return auth.MustPrincipal(ctx).ContactVerified, nil
		})
	}

	feedbackSvc := feedback.NewService(st.Feedback)
	feedbackSvc.SetKeepDays(cfg.FeedbackKeepDays)
	feedbackHandler := feedback.NewHandler(feedbackSvc, log, cfg.MaxJSONBytes, feedbackLimits, clientHost)
	feedbackHandler.SetGlobalLimiter(feedbackGlobal)

	retentionHandler := retention.NewHandler(retentionSvc, log, cfg.MaxJSONBytes, telemetryLimits, clientHost)
	retentionHandler.SetGlobalLimiter(telemetryGlobal)

	handlers := routes{
		auth:     authHandler,
		sync:     syncHandler,
		backups:  backupHandler,
		blobs:    blobHandler,
		llm:      llmProxy,
		payments: st.payments,
		llmAdmin: llmproxy.NewAdmin(llmProxy, st.Catalog, startup.box, cfg.MaxJSONBytes),
		accounts: accountadmin.New(st.Auth, st.Quota, st.Quota, st.Quota, authSvc.DeleteAccountByID,
			cfg.LLM.DailyTokens, cfg.Location, log, cfg.MaxJSONBytes),
		feedback:       feedbackHandler,
		feedbackAdmin:  feedbackadmin.New(st.Feedback, log),
		release:        release.NewHandler(cfg.Releases),
		retention:      retentionHandler,
		retentionAdmin: retentionadmin.New(retentionReporter, log),
		cloud:          cloudpurge.NewHandler(purgeSvc, log).Purge,
		schemaVersion:  ClientSchemaVersion,
		ready:          st.Ready,
	}

	// 契约之外的路径给 problem 体，而不是默认的文本 404。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
	})

	admin.RegisterUI(mux, adminGuard)
	accountGuard := auth.Middleware(authSvc, log)
	// 生成代码把 Middlewares 逐个套上，列表最后一个在最外层。运行起来依次是
	// 记录路由 → 校验身份（管理路由走管理鉴权）→ 按账号限流 → 云端写入互斥
	// → 临时文件预算 → 同步并发槽 → 标记可缓存 → 处理器。记录路由在最外层，
	// 访问日志能拿到注册模式；鉴权与限流在业务判断之前，未认证的请求不占账号
	// 额度，未验证账号的 403 与清除期间的 409 一样耗掉一次上传额度，不能拿这
	// 两条路径无限重试；云端写入互斥在临时文件预算与同步并发槽之外，被它拒绝
	// 的请求不占临时空间与同步槽；可缓存标记在最内层，只有真正要进处理器的
	// 公开响应才会被标记。
	api.HandlerWithOptions(handlers, api.StdHTTPServerOptions{
		BaseRouter: mux,
		Middlewares: []api.MiddlewareFunc{
			cachePublic,
			syncConcurrency(cfg.SyncMaxConcurrent),
			temporaryUploadBudget(cfg.UploadTempBudgetBytes, cfg.MaxBackupBytes, cfg.MaxAttachmentBytes),
			cloudOperations(cfg.DatabaseURL != ""),
			uploadLimit(uploadLimits),
			func(next http.Handler) http.Handler {
				account := accountGuard(next)
				management := adminGuard(next)
				return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if admin.IsAdminRoute(r) {
						management.ServeHTTP(w, r)
						return
					}
					account.ServeHTTP(w, r)
				})
			},
			httpx.RecordPattern,
		},
		ErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
			if admin.IsAdminRoute(r) {
				adminGuard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					httpx.BindingErrorHandler(w, r, err)
				})).ServeHTTP(w, r)
				return
			}
			httpx.BindingErrorHandler(w, r, err)
		},
	})

	if !setup {
		go authSvc.PruneLoop(ctx, st.Auth, log)
		go feedbackSvc.PruneLoop(ctx, log)
		go backupSvc.ReconcileLoop(ctx, log)
	}

	// 外层顺序从外到内：先分配 request_id 并回写响应头，再记访问日志（401/404/429
	// 也因此有编号并进日志），然后统一响应头，再恢复 panic，最后设置请求体读取
	// 期限。统一响应头在恢复 panic 之外，panic 转成的 500 也带 no-store 与
	// nosniff；鉴权与限流已经移进生成的中间件链，这里不再包一层。
	return httpx.Chain(mux,
		httpx.RequestID,
		httpx.AccessLog(log),
		httpx.SecurityHeaders,
		httpx.Recover(log),
		httpx.BodyReadTimeout(cfg.BodyIdleTimeout, cfg.BodyTotalTimeout),
	), nil
}

// cachePublic 给明确可缓存的公开响应覆盖默认的 no-store，目前只有发布清单。
// 其余响应保持默认，账号数据不会被中间层缓存。放在生成链的最内层：鉴权、
// 限流与云端写入互斥都在它之外，只有真正要进处理器的响应才会被标记。
func cachePublic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if seconds, ok := routepolicy.CacheSeconds(r.Pattern); ok {
			httpx.Cacheable(w, seconds)
		}
		next.ServeHTTP(w, r)
	})
}

// syncAttachments 把附件存储的查询适配成登记快照需要的“这个账号有没有这份
// 内容”：附件不存在不是错误，存储故障才向上返回（ADR-0043）。
type syncAttachments struct{ store blobs.Store }

func (a syncAttachments) Stat(ctx context.Context, userID, sha string) (int64, bool, error) {
	size, err := a.store.Stat(ctx, userID, sha)
	if errors.Is(err, blobs.ErrNotFound) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return size, true, nil
}
