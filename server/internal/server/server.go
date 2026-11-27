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
	"github.com/BUPT521/zhixin/server/internal/secretbox"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// ClientSchemaVersion is the client data schema this server accepts for
// sync commits and backups. It must equal the schema number at the top of
// docs/01; both sides move together and old versions are rejected (ADR-0002).
const ClientSchemaVersion = 32

// RetentionStore 既写入活跃数据（公开上报与鉴权中间件），也读取管理后台的
// 留存视图。PostgreSQL 与内存两种实现都满足，装配处因此不用做类型断言。
type RetentionStore interface {
	retention.Store
	retention.Reader
}

// Stores groups every persistence dependency so main can swap the in-memory
// implementations for PostgreSQL and object storage in one place.
type Stores struct {
	Auth    auth.Store
	Sync    syncsvc.Store
	Backups backup.Store
	Blobs   blobs.Store
	Quota   llmproxy.Quota
	Usage   llmproxy.UsageStore
	// Purchases 保存即刻收的购买入口与积分核销流水；只有 PostgreSQL 装配时提供。
	Purchases nowpay.PurchaseStore
	// Balances 保存积分余额的本地副本，额度预留按它放行免费额度之外的用量；只有
	// PostgreSQL 装配时提供，为空时预留只看免费额度（ADR-0069）。
	Balances nowpay.BalanceStore
	// NowPay 是即刻收的调用入口；没有配置商品时保持为空，购买接口只返回空余额。
	NowPay *nowpay.Client
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
	quotaStore.SetKeyLookup(authStore.KeysByUser)
	cacheStore := llmproxy.NewMemoryEmbeddingCache()
	return Stores{
		Auth:      authStore,
		Sync:      syncStore,
		Backups:   backupStore,
		Blobs:     blobStore,
		Quota:     quotaStore,
		Usage:     llmproxy.NewMemoryUsage(),
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
	}
}

// newPurchaseHandler 装配购买接口。即刻收的商品 ID 来自配置，没有配置时接口只回
// 空余额与档位。
func newPurchaseHandler(cfg config.Config, st Stores, log *slog.Logger) *nowpay.Handler {
	callback := ""
	tokensPerPoint := cfg.LLM.TokensPerPoint
	if cfg.NowPay != nil {
		callback = cfg.NowPay.CallbackURL
		if st.NowPay == nil {
			// 配了商品却没有客户端时购买接口只会回空余额，等于卖不了；这条日志
			// 让装配漏项在启动时就看得见，而不是等用户点购买才发现。
			log.Error("ZHIXIN_NOWPAY_PRODUCT_ID is set but no nowpay client is wired: purchases only return an empty balance")
		}
	}
	return nowpay.NewHandler(st.NowPay, st.Purchases, st.Balances, callback, log, cfg.RateLimitKeys, tokensPerPoint)
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
	// 没有任何一种已验证登录方式的账号按保留期删除，由 PruneLoop 的每日清理执行
	// （ADR-0037）；必须在 PruneLoop 之前设置，因为它在启动时就会先清一次。
	authSvc.SetUnverifiedKeep(cfg.UnverifiedKeepDays)
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
	mailer, err := auth.NewMailer(auth.MailerConfig{
		Addr:            cfg.SMTPAddr,
		From:            cfg.SMTPFrom,
		Username:        cfg.SMTPUsername,
		Password:        cfg.SMTPPassword,
		TLS:             cfg.SMTPTLS,
		LogOnly:         cfg.MailLog,
		MaxConcurrent:   cfg.SMTPMaxConcurrent,
		MaxAttempts:     cfg.SMTPMaxAttempts,
		RetryAfterError: auth.ParseRetryAfterHint,
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
	// 发信按登录方式分发：现在只有邮箱走 SMTP，手机号与微信没有对应发送方时
	// 请求返回 501（ADR-0038）。
	authSvc.ConfigureCodes(auth.NewSenders(mailer), codeSecret, cfg.CodeTTL, cfg.CodeCooldown)
	// 收信预算的键是 kind:identifier：同一地址每 24 小时补充 4 枚，最多积存 4 枚。
	authSvc.SetSendLimiter(ratelimit.New(rate.Limit(4/(24*time.Hour).Seconds()), 4, 48*time.Hour, cfg.RateLimitKeys))
	// 实例级的发信总量：换地址与换收件地址都绕不过去，给 SMTP 服务商的配额兜底。
	authSvc.SetGlobalSendLimiter(ratelimit.NewGlobal(ratelimit.Limit{
		PerSecond: cfg.MailGlobalRatePerSecond,
		Burst:     cfg.MailGlobalBurst,
	}))

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

	backupSvc := backup.NewService(st.Backups, cfg.MaxBackupBytes, cfg.BackupsKept, ClientSchemaVersion)
	// 备份的元数据与字节分两步写，中断会留下没有元数据的对象：按周期对账一次，
	// 删掉库里查不到、且写于一小时之前的遗留字节（ADR-0037）。
	backupSvc.SetObjects(st.Objects)
	backupSvc.SetReconcileInterval(cfg.BackupReconcileInterval)
	backupHandler := backup.NewHandler(backupSvc, log)

	// 账号附件总量上限必须显式设置，否则只受单附件上限约束。
	blobSvc := blobs.NewService(st.Blobs, cfg.MaxAttachmentBytes).SetAccountBytes(cfg.MaxAccountAttachmentBytes)
	blobHandler := blobs.NewHandler(blobSvc, log)
	// 快照登记要核对“这个哈希是这个账号的附件”，查询由附件服务提供；没有装配时
	// 登记接口返回 501，不静默接受一个查不到归属的哈希（ADR-0043）。
	syncSvc.SetAttachments(syncAttachments{svc: blobSvc})

	// 云端清除编排备份、提交序列、附件与遗留对象；清除与写请求的互斥、清除
	// 期间写请求的 409 由进程内的 cloudOperations 中间件保证（审查 9.3 的 V10）。
	purgeSvc := cloudpurge.New(st.Backups, st.Sync, st.Blobs, st.Cache, st.Objects)

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
	router := llmproxy.NewRouter(st.Catalog, box, log)
	if err := router.Reload(ctx); err != nil {
		log.Error("load model routes; serving the last snapshot until the next reload", slog.String("error", err.Error()))
	} else if router.ModelCount() == 0 {
		// 来源与模型都只在管理后台配置（ADR-0035）：空库启动时聊天与嵌入接口会
		// 一律返回 503，这里先把原因说清楚。
		log.Warn("no model configured: add a source and a model in /admin/ before serving hosted models")
	}
	var adminLimits *ratelimit.Limiter
	if cfg.AdminRatePerSecond > 0 {
		adminLimits = ratelimit.New(rate.Limit(cfg.AdminRatePerSecond), cfg.AdminBurst, 15*time.Minute, cfg.RateLimitKeys)
	}

	adminGuard := admin.Middleware(admin.Options{Token: cfg.AdminToken, Limiter: adminLimits, ClientHost: clientHost})

	llmProxy := llmproxy.NewRoutedHandler(cfg.LLM, router, st.Quota, cfg.Location, log)
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
	go feedbackSvc.PruneLoop(ctx, log)

	retentionHandler := retention.NewHandler(retentionSvc, log, cfg.MaxJSONBytes, telemetryLimits, clientHost)
	retentionHandler.SetGlobalLimiter(telemetryGlobal)

	// 备份对账只在 PostgreSQL 装配下有事可做：内存备份把字节留在自己的存储里，
	// 对象存储里没有 backups/ 前缀可列，启动那一次是无害的空跑。
	go backupSvc.ReconcileLoop(ctx, log)

	handlers := routes{
		auth:     authHandler,
		sync:     syncHandler,
		backups:  backupHandler,
		blobs:    blobHandler,
		llm:      llmProxy,
		payments: newPurchaseHandler(cfg, st, log),
		llmAdmin: llmproxy.NewAdmin(llmProxy, st.Catalog, box, cfg.MaxJSONBytes),
		accounts: accountadmin.New(st.Auth, st.Quota, authSvc.DeleteAccountByID,
			cfg.LLM.DailyTokens, cfg.LLM.EmbeddingDailyTokens, cfg.Location, log, cfg.MaxJSONBytes),
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
		ErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
			if _, path, _ := strings.Cut(r.Pattern, " "); strings.HasPrefix(path, "/admin/v1/") {
				adminGuard(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					httpx.BindingErrorHandler(w, r, err)
				})).ServeHTTP(w, r)
				return
			}
			httpx.BindingErrorHandler(w, r, err)
		},
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

// syncAttachments 把附件服务的查询适配成登记快照需要的“这个账号有没有这份
// 内容”：附件不存在不是错误，存储故障才向上返回（ADR-0043）。
type syncAttachments struct{ svc *blobs.Service }

func (a syncAttachments) Stat(ctx context.Context, userID, sha string) (int64, bool, error) {
	size, err := a.svc.Stat(ctx, userID, sha)
	if errors.Is(err, blobs.ErrNotFound) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return size, true, nil
}
