// Package config reads the server configuration from environment variables.
//
// Every secret (database password, upstream model key, admin token, the key
// that encrypts provider keys in the database) arrives through the
// environment; nothing is read from files in the repository. The one exception
// is the release manifest: its path comes from ZHIXIN_RELEASE_FILE and the file
// itself lives outside the repository. See ADR-0009 and ADR-0025.
package config

import (
	"errors"
	"fmt"
	"math"
	"net"
	"net/mail"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/payment"
	"github.com/BUPT521/zhixin/server/internal/release"
	"github.com/BUPT521/zhixin/server/internal/secretbox"
)

// Config is the complete runtime configuration of zhixin-api.
type Config struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// DatabaseURL is the PostgreSQL DSN. Empty means the in-memory store,
	// which is only for local development and tests.
	DatabaseURL string
	// Alipay 是即刻收复用的支付宝应用凭证；为空表示这个实例没有配置收款。
	Alipay *payment.Gateway
	// NowPay 是即刻收直连的商品配置；为空表示不卖积分包，购买接口只回空余额。
	NowPay *NowPayConfig
	// Location decides where a "day" starts for the model quota.
	Location *time.Location

	AccessTTL  time.Duration
	RefreshTTL time.Duration

	// MaxJSONBytes caps ordinary JSON request bodies.
	MaxJSONBytes int64
	// BodyIdleTimeout 是读取请求体时两次读到数据之间允许的最长等待。读完、关闭
	// 或出错时清除，避免影响后续的 SSE 响应。
	BodyIdleTimeout time.Duration
	// BodyTotalTimeout limits the time to receive the complete request body.
	BodyTotalTimeout time.Duration
	// MaxBackupBytes caps a single uploaded backup snapshot.
	MaxBackupBytes int64
	// MaxAttachmentBytes caps one uploaded attachment object.
	MaxAttachmentBytes int64
	// UploadTempBudgetBytes caps the space reserved by concurrent backup and attachment uploads.
	UploadTempBudgetBytes int64
	// SyncMaxConcurrent caps sync commit pulls and pushes together per instance.
	SyncMaxConcurrent int64
	// MaxAccountAttachmentBytes 是一个账号全部附件的总量上限；超过时上传返回
	// 413 storage_full，并带上已用量与上限。
	MaxAccountAttachmentBytes int64
	// SyncPullMaxBytes 是一次拉取响应的字节上限：分页按它提前收尾，has_more
	// 为真，客户端继续拉下一页。
	SyncPullMaxBytes int64
	// SyncCompactKeep 是快照位置之下仍然保留提交的时间窗口：登记快照时，早于它
	// 的已覆盖提交删除，落后不多的设备因此不必重新克隆（ADR-0043）。
	SyncCompactKeep time.Duration
	// SyncCompact 打开快照压缩：关闭时登记只写指针、推送遇到预算压力也不按快照
	// 删提交，仍超限就返回 storage_full（ADR-0047）。默认关闭。
	SyncCompact bool
	// SyncSnapshotGrace 是旧快照附件的回收宽限期：登记新快照之后，让位时间早于
	// 它减去当前时间的旧字节才会删除（ADR-0047）。
	SyncSnapshotGrace time.Duration
	// SyncDeviceActive 是压缩门槛看设备是否活跃的时间窗口：最近这段时间内出现过
	// 的设备只要有一台没有声明 snapshot，就不删提交（ADR-0047）。
	SyncDeviceActive time.Duration
	// BackupsKept is how many snapshots are retained per account.
	BackupsKept int
	// BackupReconcileInterval 是对象存储对账的周期：列出 backups/ 下的对象，
	// 库里找不到对应元数据的遗留字节删掉（ADR-0037）。设 0 表示只在启动时对账
	// 一次，之后不再重跑。
	BackupReconcileInterval time.Duration
	// BlobDir is the local directory for backup and attachment bytes. Used
	// when S3 is not configured.
	BlobDir string
	// S3 configures S3-compatible object storage; an empty endpoint means the
	// local directory is used instead (ADR-0016).
	S3 objectstore.S3Config
	// ApplySchema runs schema.sql on startup; meant for a fresh database.
	ApplySchema bool

	// AuthRatePerSecond 与 AuthBurst 是登录、注册按来源地址的令牌桶参数；
	// RefreshRatePerSecond 与 RefreshBurst 是刷新令牌按账号与地址的参数。
	// 设 AuthRatePerSecond 为 0 关闭限流（本地联调与测试用）。
	AuthRatePerSecond    float64
	AuthBurst            int
	RefreshRatePerSecond float64
	RefreshBurst         int
	// LoginFailRatePerSecond 与 LoginFailBurst 是按规范化邮箱计数的登录失败
	// 预算：默认约每分钟补一个令牌、最多攒十个，超出的尝试短暂返回 429。
	LoginFailRatePerSecond float64
	LoginFailBurst         int
	// RegisterGlobalRatePerSecond 与 RegisterGlobalBurst 是注册的全局上限：
	// 每个来源地址的桶之外再限制整个实例的注册总量，换地址也不能把未验证的账号
	// 灌满库（ADR-0037）。设 0 关闭。
	RegisterGlobalRatePerSecond float64
	RegisterGlobalBurst         int
	// RegisterEmailDomains 是注册允许的邮箱域名，按 @ 之后的部分精确匹配，
	// 例如 bupt.cn。为空表示不限制后缀；* 表示不限制（ADR-0085）。
	RegisterEmailDomains []string
	// UnverifiedKeepDays 是未确认邮箱的账号保留天数：注册之后超过这么多天仍未
	// 确认的账号由每日清理删除，释放邮箱与账号行（ADR-0037）。
	UnverifiedKeepDays int
	// Argon2MemoryBudgetMiB 是密码哈希同时占用的内存预算；并发上限由它除以
	// 单次哈希的 19 MiB 算出，注册、登录、重设密码与删号共用这个上限。
	Argon2MemoryBudgetMiB int
	// MaxSessionsPerUser 是每个账号保留的会话数上限，新登录超过时删最旧的。
	MaxSessionsPerUser int
	// RateLimitKeys 是每个进程内限流器保留的最大桶数；超过时清理空闲桶或淘汰
	// 最久未用的键，避免按地址分桶的表无限增长。
	RateLimitKeys int

	// UploadRatePerSecond 与 UploadBurst 限制备份与附件上传按账号的速率；
	// 这两类请求会先落临时文件，设 0 关闭。
	UploadRatePerSecond float64
	UploadBurst         int

	// 邮箱验证与找回密码的发信。SMTPAddr 为空时这些接口返回 503；MailLog
	// 只在本机联调时把邮件写进日志，生产不能打开。
	SMTPAddr     string
	SMTPFrom     string
	SMTPUsername string
	SMTPPassword string
	SMTPTLS      string
	MailLog      bool
	// CodeSecret 是验证码 HMAC 的密钥；为空时每次启动随机生成，旧验证码随
	// 重启失效。生产应固定一个随机值，才不会因为重启让用户重发。
	CodeSecret string
	CodeTTL    time.Duration
	// CodeCooldown 是同一账号两次发送验证码的最小间隔。
	CodeCooldown time.Duration
	// CodeRatePerSecond 与 CodeBurst 限制发送验证码与重设密码的尝试，按账号
	// 或来源地址计；设 0 关闭。
	CodeRatePerSecond float64
	CodeBurst         int
	// MailGlobalRatePerSecond 与 MailGlobalBurst 是整个实例的发信上限，与按地址、
	// 按收件地址的桶同时生效：换大量新邮箱请求验证码也绕不过去。设 0 关闭。
	MailGlobalRatePerSecond float64
	MailGlobalBurst         int
	// SMTPMaxConcurrent 是同时占用的 SMTP 连接数，SMTPMaxAttempts 是一次发送
	// 对临时失败的总尝试次数。
	SMTPMaxConcurrent int
	SMTPMaxAttempts   int

	// FeedbackRatePerSecond 与 FeedbackBurst 限制应用内反馈的提交，按来源地址
	// 计；设 0 关闭。
	FeedbackRatePerSecond float64
	FeedbackBurst         int
	// FeedbackGlobalRatePerSecond 与 FeedbackGlobalBurst 是反馈写入的全局上限，
	// 与按地址的桶同时生效，防止换地址把整张表刷满。
	FeedbackGlobalRatePerSecond float64
	FeedbackGlobalBurst         int
	// FeedbackKeepDays 是反馈的保留天数；更早的行由每日清理删除，正文与联系
	// 方式不无限期保留。设 0 关闭每日清理。
	FeedbackKeepDays int
	// TelemetrySecret 是匿名安装标识的 HMAC 密钥（ADR-0019）；为空时每次启动
	// 随机生成，重启后同一个安装会被当成新的，留存数字偏高。
	TelemetrySecret string
	// TelemetryRatePerSecond 与 TelemetryBurst 限制匿名活跃上报，按来源地址计；
	// 设 0 关闭。
	TelemetryRatePerSecond float64
	TelemetryBurst         int
	// TelemetryGlobalRatePerSecond 与 TelemetryGlobalBurst 是匿名上报的全局写入
	// 上限，含义与反馈的全局上限相同。
	TelemetryGlobalRatePerSecond float64
	TelemetryGlobalBurst         int
	// TrustedProxies 是允许写入 X-Forwarded-For 的反向代理地址或网段。只有直接
	// 对端落在其中时才相信这个头的末项；没有配置时只看直接对端，客户端自己写
	// 这个头也换不到另一个限流桶。
	TrustedProxies []netip.Prefix

	// ReleaseFile 是发布清单文件；为空表示还没有对外发布过安装包，更新检查
	// 返回空数组。
	ReleaseFile string
	// Releases 是启动时从 ReleaseFile 读入并校验过的清单，见 release.Load。
	Releases []release.Entry

	LLM LLMConfig

	// AdminToken 是管理后台的令牌；为空时 /admin 一律 404。
	AdminToken string
	// AdminRatePerSecond 与 AdminBurst 限制管理令牌校验失败的次数，按来源地址
	// 计；设 0 关闭。
	AdminRatePerSecond float64
	AdminBurst         int
	// SecretKey 是加密数据库里模型来源 key 的 32 字节密钥（ZHIXIN_SECRET_KEY）。
	// 为空时不能保存带 key 的来源，已保存的 key 也无法解密。
	SecretKey []byte
}

// NowPayConfig 是即刻收直连的商品配置（ZHIXIN_NOWPAY_*），决定按积分包卖聊天
// 额度。商品、档位与价格都在「即刻收」小程序里配置，这里只放商品 ID、返回地址与
// 积分折算比例。
type NowPayConfig struct {
	// ProductID 是小程序商品详情页复制的外部商品 ID，不能由应用生成。
	ProductID string
	// CallbackURL 只在购买页返回之后跳转用，不是到账通知；留空时由客户端自己回到
	// 应用。配置时必须是 HTTPS 地址。
	CallbackURL string
}

// parseNowPay 读即刻收的商品配置并做自检。商品 ID 走 128 个字符以内的字母数字与
// 连接符，保持与支付宝返回的形态一致，也避免把配置错误带进签名。积分折算比例在
// LLMConfig 里统一读取，购买、核销与前台展示共用同一个值。
func parseNowPay(get func(string, string) string, productID string) (*NowPayConfig, error) {
	if len(productID) > 128 || !productIDPattern.MatchString(productID) {
		return nil, errors.New("ZHIXIN_NOWPAY_PRODUCT_ID 必须是「即刻收」小程序里的商品 ID")
	}
	callback := strings.TrimSpace(get("ZHIXIN_NOWPAY_CALLBACK_URL", ""))
	if callback != "" {
		parsed, err := url.Parse(callback)
		if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" ||
			parsed.User != nil || parsed.Fragment != "" || len(callback) > 512 {
			return nil, errors.New("ZHIXIN_NOWPAY_CALLBACK_URL 必须是 HTTPS 地址，且不带账号信息与片段")
		}
	}
	return &NowPayConfig{ProductID: productID, CallbackURL: callback}, nil
}

var productIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{4,128}$`)

// LLMConfig configures the model proxy.
//
// Sources and models come from the admin page (llm_provider, llm_model and
// llm_route); there is no environment-variable source any more, see
// ADR-0035.
type LLMConfig struct {
	// RestrictProviders requires public HTTPS endpoints for database sources.
	RestrictProviders bool
	// DailyTokens is the per-account free daily budget shared by chat and embeddings.
	DailyTokens int64
	// TokensPerPoint 是一个积分覆盖的计费 token 数：即刻收按它把 Usage.Billed
	// 折算成积分核销，客户端按它把 token 用量换算成积分展示（ADR-0068）。
	TokensPerPoint int64
	// InstanceDailyTokens 是整个实例一天的总 token 预算；用尽之后所有账号的
	// 托管请求都返回 429，防止单个实例的提供方账单失控。
	InstanceDailyTokens int64
	// MaxRequestBytes caps a proxied request body (images are inlined as base64).
	MaxRequestBytes int64
	// RequireVerifiedContact 要求账号至少有一种登录方式已经确认才开放托管额度；
	// 为真时聊天与嵌入入口对没有确认过的账号返回 403 contact_unverified。
	RequireVerifiedContact bool
	// ConcurrentPerUser 是同一账号同时进行的托管请求上限；在读取请求体之前就
	// 检查，超出的请求直接 429。
	ConcurrentPerUser int
	// MaxInstanceBytes 是整个实例同时在途的托管请求可占用的内存上限，按字节计。
	// 请求体、非流式响应与嵌入批次在读写之前从这一份预算里预留，占不到时返回
	// 429；它把实例内存与账号数量解耦（ADR-0036）。输出上限放大到 32768 token
	// 之后，默认值跟着放大到 512 MiB，同时在途的请求数因此不会被压到个位数
	// （ADR-0053）。
	MaxInstanceBytes int64
	// MaxResponseBytes 是一次响应的字节上限。非流式响应超过时按
	// upstream_failed 处理，避免一次请求把内存与带宽占满；流式响应超过时由代理
	// 结束转发，已经转出的内容照常交付，这次结束不记来源故障。
	MaxResponseBytes int64
	// StreamIdleTimeout 是流式响应两次收到数据之间的最长等待；超过时中断上游
	// 请求并结束响应。
	StreamIdleTimeout time.Duration
	// StreamTotalTimeout 是一次流式响应的总时限。
	StreamTotalTimeout time.Duration
	// EmbeddingBillingPermille is the billed tokens per thousand raw embedding
	// tokens. The default 2500 aligns the two kinds by cost: Bailian's real-time
	// input price is 0.50 CNY per million raw tokens and the channel price for
	// chat is 0.20 CNY per million billed tokens.
	EmbeddingBillingPermille int64
	// EmbeddingMaxInputs caps the number of inputs in one embeddings request.
	EmbeddingMaxInputs int
	// EmbeddingCacheBytes 是每个账号的嵌入向量缓存上限（ADR-0030）：写入之后按
	// last_used_at 删除最久未用的行，超出的向量下一次刷新重新嵌入。
	EmbeddingCacheBytes int64
	// MaxAttempts caps how many sources one request may try.
	MaxAttempts int
	// HeaderTimeout is how long a source may take to send response headers for
	// a streamed chat or an embeddings request before the next source is tried.
	HeaderTimeout time.Duration
	// FirstOutputTimeout 是一次流式聊天尝试等待首个有效输出的上限，答案是多条
	// 候选时再按本轮剩余预算平分，首发与备用因此都落在同一轮预算内。它只约束
	// 首个输出之前，交付正文之后的等待由 StreamIdleTimeout 约束。
	FirstOutputTimeout time.Duration
	// RoundBudgetMax 是服务端接受的本轮预算上限：客户端在请求头里带本轮剩余
	// 时间，值再大也只按这个上限执行，整段回答、空闲等待与首字等待都不超过它。
	RoundBudgetMax time.Duration
	// ForegroundReserved 是每个账号为聊天与检索查询保留的并发名额：材料导入与
	// 索引补算只能使用其余名额，两者合计仍不超过 ConcurrentPerUser。后台至少
	// 保留一个名额，所以设得等于并发上限也不会把后台完全挡住；设 0 表示不为
	// 前台保留，后台可以使用全部名额。
	ForegroundReserved int
	// BackgroundInstancePercent 是实例在途字节预算中后台批次最多占用的百分比，
	// 其余留给前台。0 与 100 都表示不单独限制后台，具体比例按并发走查确定。
	BackgroundInstancePercent int
}

// Load builds a Config from getenv (normally os.Getenv).
func Load(getenv func(string) string) (Config, error) {
	var errs []error
	get := func(key, def string) string {
		if v := strings.TrimSpace(getenv(key)); v != "" {
			return v
		}
		return def
	}
	fnum := func(key, def string) float64 {
		v := get(key, def)
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 {
			errs = append(errs, fmt.Errorf("%s: want a non-negative number such as 0.2", key))
			return 0
		}
		return f
	}
	dur := func(key, def string) time.Duration {
		d, err := time.ParseDuration(get(key, def))
		if err != nil || d <= 0 {
			errs = append(errs, fmt.Errorf("%s: want a positive duration such as 1h", key))
		}
		return d
	}
	num := func(key, def string) int64 {
		n, err := strconv.ParseInt(get(key, def), 10, 64)
		if err != nil || n <= 0 {
			errs = append(errs, fmt.Errorf("%s: want a positive integer", key))
		}
		return n
	}
	// nonnegNum 解析允许取 0 的整数：这类配置用 0 表示关闭或“不单独限制”。
	nonnegNum := func(key, def string) int64 {
		n, err := strconv.ParseInt(get(key, def), 10, 64)
		if err != nil || n < 0 {
			errs = append(errs, fmt.Errorf("%s: want a non-negative integer such as 0", key))
		}
		return n
	}
	// nonnegDur 解析允许取 0 的时长：0 表示关闭周期任务，启动时那次照常执行。
	nonnegDur := func(key, def string) time.Duration {
		d, err := time.ParseDuration(get(key, def))
		if err != nil || d < 0 {
			errs = append(errs, fmt.Errorf("%s: want 0 or a positive duration such as 1h", key))
		}
		return d
	}

	loc, err := time.LoadLocation(get("ZHIXIN_TIMEZONE", "Asia/Shanghai"))
	if err != nil {
		errs = append(errs, fmt.Errorf("ZHIXIN_TIMEZONE: %w", err))
	}

	proxies, err := parseTrustedProxies(get("ZHIXIN_TRUSTED_PROXIES", ""))
	if err != nil {
		errs = append(errs, err)
	}

	// 内测期间注册只接受学校邮箱，默认 bupt.cn；公测开放注册时把这一项写成 *。
	registerEmailDomains, err := parseRegisterEmailDomains(get("ZHIXIN_REGISTER_EMAIL_DOMAINS", "bupt.cn"))
	if err != nil {
		errs = append(errs, err)
	}

	cfg := Config{
		Addr:                      get("ZHIXIN_ADDR", ":8080"),
		DatabaseURL:               get("ZHIXIN_DATABASE_URL", ""),
		Location:                  loc,
		AccessTTL:                 dur("ZHIXIN_ACCESS_TTL", "1h"),
		RefreshTTL:                dur("ZHIXIN_REFRESH_TTL", "720h"),
		MaxJSONBytes:              num("ZHIXIN_MAX_JSON_BYTES", "1048576"),
		BodyIdleTimeout:           dur("ZHIXIN_BODY_IDLE_TIMEOUT", "60s"),
		BodyTotalTimeout:          dur("ZHIXIN_BODY_TOTAL_TIMEOUT", "30m"),
		MaxBackupBytes:            num("ZHIXIN_MAX_BACKUP_BYTES", "268435456"),
		MaxAttachmentBytes:        num("ZHIXIN_MAX_ATTACHMENT_BYTES", "33554432"),
		MaxAccountAttachmentBytes: num("ZHIXIN_MAX_ACCOUNT_ATTACHMENT_BYTES", "2147483648"),
		SyncMaxConcurrent:         num("ZHIXIN_SYNC_MAX_CONCURRENT", "4"),
		SyncPullMaxBytes:          num("ZHIXIN_SYNC_PULL_MAX_BYTES", "4194304"),
		SyncCompactKeep:           dur("ZHIXIN_SYNC_COMPACT_KEEP", "168h"),
		SyncCompact:               get("ZHIXIN_SYNC_COMPACT", "0") == "1",
		SyncSnapshotGrace:         dur("ZHIXIN_SYNC_SNAPSHOT_GRACE", "24h"),
		SyncDeviceActive:          dur("ZHIXIN_SYNC_DEVICE_ACTIVE", "720h"),
		BackupsKept:               int(num("ZHIXIN_BACKUPS_KEPT", "5")),
		BackupReconcileInterval:   nonnegDur("ZHIXIN_BACKUP_RECONCILE_INTERVAL", "24h"),
		BlobDir:                   get("ZHIXIN_BLOB_DIR", "data/blobs"),
		ApplySchema:               get("ZHIXIN_APPLY_SCHEMA", "0") == "1",
		S3: objectstore.S3Config{
			Endpoint:  get("ZHIXIN_S3_ENDPOINT", ""),
			Bucket:    get("ZHIXIN_S3_BUCKET", "zhixin"),
			AccessKey: get("ZHIXIN_S3_ACCESS_KEY", ""),
			SecretKey: get("ZHIXIN_S3_SECRET_KEY", ""),
			Region:    get("ZHIXIN_S3_REGION", ""),
			UseSSL:    get("ZHIXIN_S3_USE_SSL", "0") == "1",
		},

		AuthRatePerSecond:           fnum("ZHIXIN_AUTH_RATE", "0.2"),
		AuthBurst:                   int(num("ZHIXIN_AUTH_BURST", "10")),
		RefreshRatePerSecond:        fnum("ZHIXIN_REFRESH_RATE", "1"),
		RefreshBurst:                int(num("ZHIXIN_REFRESH_BURST", "30")),
		LoginFailRatePerSecond:      fnum("ZHIXIN_LOGIN_FAIL_RATE", "0.017"),
		LoginFailBurst:              int(num("ZHIXIN_LOGIN_FAIL_BURST", "10")),
		RegisterGlobalRatePerSecond: fnum("ZHIXIN_REGISTER_GLOBAL_RATE", "0.05"),
		RegisterGlobalBurst:         int(num("ZHIXIN_REGISTER_GLOBAL_BURST", "10")),
		RegisterEmailDomains:        registerEmailDomains,
		UnverifiedKeepDays:          int(num("ZHIXIN_UNVERIFIED_KEEP_DAYS", "7")),
		Argon2MemoryBudgetMiB:       int(num("ZHIXIN_ARGON2_MEMORY_BUDGET_MIB", "256")),
		MaxSessionsPerUser:          int(num("ZHIXIN_MAX_SESSIONS_PER_USER", "20")),
		RateLimitKeys:               int(num("ZHIXIN_RATE_LIMIT_KEYS", "100000")),
		UploadRatePerSecond:         fnum("ZHIXIN_UPLOAD_RATE", "0.5"),
		UploadBurst:                 int(num("ZHIXIN_UPLOAD_BURST", "5")),

		SMTPAddr:          get("ZHIXIN_SMTP_ADDR", ""),
		SMTPFrom:          get("ZHIXIN_SMTP_FROM", ""),
		SMTPUsername:      get("ZHIXIN_SMTP_USERNAME", ""),
		SMTPPassword:      get("ZHIXIN_SMTP_PASSWORD", ""),
		SMTPTLS:           get("ZHIXIN_SMTP_TLS", "starttls"),
		MailLog:           get("ZHIXIN_MAIL_LOG", "0") == "1",
		CodeSecret:        get("ZHIXIN_CODE_SECRET", ""),
		CodeTTL:           dur("ZHIXIN_CODE_TTL", "10m"),
		CodeCooldown:      dur("ZHIXIN_CODE_COOLDOWN", "60s"),
		CodeRatePerSecond: fnum("ZHIXIN_CODE_RATE", "0.02"),
		CodeBurst:         int(num("ZHIXIN_CODE_BURST", "1")),
		// 发信总量按服务商免费额的保守值定：日发 200 封折成每秒约 0.002 封，
		// 高峰一小时发 60 封折成每秒约 0.017 封，取 0.05 留三倍余量，桶容量 20。
		// 具体通道的日上限与每小时上限不同，部署时按实际通道调，见运维手册。
		MailGlobalRatePerSecond: fnum("ZHIXIN_MAIL_GLOBAL_RATE", "0.05"),
		MailGlobalBurst:         int(num("ZHIXIN_MAIL_GLOBAL_BURST", "20")),
		SMTPMaxConcurrent:       int(num("ZHIXIN_SMTP_MAX_CONCURRENT", "4")),
		SMTPMaxAttempts:         int(num("ZHIXIN_SMTP_MAX_ATTEMPTS", "3")),

		FeedbackRatePerSecond:       fnum("ZHIXIN_FEEDBACK_RATE", "0.02"),
		FeedbackBurst:               int(num("ZHIXIN_FEEDBACK_BURST", "3")),
		FeedbackGlobalRatePerSecond: fnum("ZHIXIN_FEEDBACK_GLOBAL_RATE", "2"),
		FeedbackGlobalBurst:         int(num("ZHIXIN_FEEDBACK_GLOBAL_BURST", "30")),
		FeedbackKeepDays:            int(nonnegNum("ZHIXIN_FEEDBACK_KEEP_DAYS", "365")),

		TelemetrySecret:              get("ZHIXIN_TELEMETRY_SECRET", ""),
		TelemetryRatePerSecond:       fnum("ZHIXIN_TELEMETRY_RATE", "0.2"),
		TelemetryBurst:               int(num("ZHIXIN_TELEMETRY_BURST", "20")),
		TelemetryGlobalRatePerSecond: fnum("ZHIXIN_TELEMETRY_GLOBAL_RATE", "5"),
		TelemetryGlobalBurst:         int(num("ZHIXIN_TELEMETRY_GLOBAL_BURST", "100")),

		TrustedProxies: proxies,

		ReleaseFile: get("ZHIXIN_RELEASE_FILE", ""),

		LLM: LLMConfig{
			RestrictProviders:         get("ZHIXIN_DATABASE_URL", "") != "",
			DailyTokens:               num("ZHIXIN_LLM_DAILY_TOKENS", "400000"),
			TokensPerPoint:            num("ZHIXIN_TOKENS_PER_POINT", "10000"),
			InstanceDailyTokens:       num("ZHIXIN_LLM_INSTANCE_DAILY_TOKENS", "32000000"),
			MaxRequestBytes:           num("ZHIXIN_LLM_MAX_REQUEST_BYTES", "8388608"),
			RequireVerifiedContact:    get("ZHIXIN_LLM_REQUIRE_VERIFIED_CONTACT", "1") == "1",
			ConcurrentPerUser:         int(num("ZHIXIN_LLM_CONCURRENT_PER_USER", "4")),
			MaxInstanceBytes:          num("ZHIXIN_LLM_MAX_INSTANCE_BYTES", "536870912"),
			MaxResponseBytes:          num("ZHIXIN_LLM_MAX_RESPONSE_BYTES", "33554432"),
			StreamIdleTimeout:         dur("ZHIXIN_LLM_STREAM_IDLE_TIMEOUT", "90s"),
			StreamTotalTimeout:        dur("ZHIXIN_LLM_STREAM_TOTAL_TIMEOUT", "30m"),
			EmbeddingBillingPermille:  num("ZHIXIN_LLM_EMBEDDING_BILLING_PERMILLE", "2500"),
			EmbeddingMaxInputs:        int(num("ZHIXIN_LLM_EMBEDDING_MAX_INPUTS", "256")),
			EmbeddingCacheBytes:       num("ZHIXIN_LLM_EMBEDDING_CACHE_BYTES", "1073741824"),
			MaxAttempts:               int(num("ZHIXIN_LLM_MAX_ATTEMPTS", "3")),
			HeaderTimeout:             dur("ZHIXIN_LLM_HEADER_TIMEOUT", "60s"),
			FirstOutputTimeout:        dur("ZHIXIN_LLM_FIRST_OUTPUT_TIMEOUT", "20s"),
			RoundBudgetMax:            dur("ZHIXIN_LLM_ROUND_BUDGET_MAX", "5m"),
			ForegroundReserved:        int(nonnegNum("ZHIXIN_LLM_FOREGROUND_RESERVED", "2")),
			BackgroundInstancePercent: int(nonnegNum("ZHIXIN_LLM_BACKGROUND_INSTANCE_PERCENT", "60")),
		},

		AdminToken:         get("ZHIXIN_ADMIN_TOKEN", ""),
		AdminRatePerSecond: fnum("ZHIXIN_ADMIN_RATE", "0.05"),
		AdminBurst:         int(num("ZHIXIN_ADMIN_BURST", "5")),
	}
	const uploadBudgetKey = "ZHIXIN_UPLOAD_TEMP_BUDGET_BYTES"
	const defaultUploadConcurrency = 4
	maxUploadBytes := max(cfg.MaxBackupBytes, cfg.MaxAttachmentBytes)
	if get(uploadBudgetKey, "") != "" {
		cfg.UploadTempBudgetBytes = num(uploadBudgetKey, "")
		if cfg.UploadTempBudgetBytes > 0 && cfg.UploadTempBudgetBytes < maxUploadBytes {
			errs = append(errs, fmt.Errorf("%s: must cover the larger of ZHIXIN_MAX_BACKUP_BYTES and ZHIXIN_MAX_ATTACHMENT_BYTES (%d bytes)", uploadBudgetKey, maxUploadBytes))
		}
	} else if maxUploadBytes > math.MaxInt64/defaultUploadConcurrency {
		errs = append(errs, fmt.Errorf("%s: set explicitly because the default upload budget exceeds int64", uploadBudgetKey))
	} else {
		cfg.UploadTempBudgetBytes = maxUploadBytes * defaultUploadConcurrency
	}
	if cfg.AdminToken != "" && len(cfg.AdminToken) < 32 {
		errs = append(errs, errors.New("ZHIXIN_ADMIN_TOKEN: use at least 32 characters, e.g. `openssl rand -base64 32`"))
	}
	if cfg.LLM.TokensPerPoint > 1000000000 {
		errs = append(errs, errors.New("ZHIXIN_TOKENS_PER_POINT 必须是 1 到 10 亿之间的整数"))
	}
	if cfg.LLM.EmbeddingBillingPermille < 1 || cfg.LLM.EmbeddingBillingPermille > 10000 {
		errs = append(errs, errors.New("ZHIXIN_LLM_EMBEDDING_BILLING_PERMILLE: want 1 to 10000"))
	}
	if cfg.LLM.BackgroundInstancePercent > 100 {
		errs = append(errs, errors.New("ZHIXIN_LLM_BACKGROUND_INSTANCE_PERCENT: want 0 to 100"))
	}
	if raw := get("ZHIXIN_SECRET_KEY", ""); raw != "" {
		key, err := secretbox.ParseKey(raw)
		if err != nil {
			errs = append(errs, fmt.Errorf("ZHIXIN_SECRET_KEY: %w", err))
		}
		cfg.SecretKey = key
	} else if cfg.AdminToken != "" && cfg.DatabaseURL != "" {
		// 后台打开、数据库也在用时，key 必须加密入库；没有密钥就等于后台只能
		// 配置不带 key 的来源，这多半是漏配，直接报错比悄悄降级好。
		errs = append(errs, errors.New("ZHIXIN_SECRET_KEY is required when ZHIXIN_ADMIN_TOKEN and ZHIXIN_DATABASE_URL are set"))
	}
	if cfg.S3.Configured() {
		if cfg.S3.AccessKey == "" || cfg.S3.SecretKey == "" {
			errs = append(errs, errors.New("ZHIXIN_S3_ACCESS_KEY and ZHIXIN_S3_SECRET_KEY are required when ZHIXIN_S3_ENDPOINT is set"))
		}
		if strings.Contains(cfg.S3.Endpoint, "://") {
			errs = append(errs, errors.New("ZHIXIN_S3_ENDPOINT: give host and port only; use ZHIXIN_S3_USE_SSL to pick https"))
		}
	}
	if cfg.SMTPAddr != "" {
		if cfg.SMTPFrom == "" {
			errs = append(errs, errors.New("ZHIXIN_SMTP_FROM is required when ZHIXIN_SMTP_ADDR is set"))
		} else if _, err := mail.ParseAddress(cfg.SMTPFrom); err != nil {
			errs = append(errs, fmt.Errorf("ZHIXIN_SMTP_FROM: %w", err))
		}
		switch cfg.SMTPTLS {
		case "starttls", "implicit", "none":
		default:
			errs = append(errs, fmt.Errorf("ZHIXIN_SMTP_TLS: want starttls, implicit or none, got %q", cfg.SMTPTLS))
		}
		if cfg.SMTPUsername != "" && cfg.SMTPPassword == "" {
			errs = append(errs, errors.New("ZHIXIN_SMTP_PASSWORD is required when ZHIXIN_SMTP_USERNAME is set"))
		}
	}
	// 带认证的信连接如果跨出本机又不加密，口令与验证码会以明文经过网络；
	// 只允许回环地址在 none 模式下联调。
	if cfg.SMTPAddr != "" && cfg.SMTPUsername != "" && cfg.SMTPTLS == "none" {
		if host := smtpHost(cfg.SMTPAddr); !isLoopbackHost(host) {
			errs = append(errs, fmt.Errorf("ZHIXIN_SMTP_TLS: 带认证的非回环 SMTP 连接必须使用 starttls 或 implicit，不能是 none（%s）", host))
		}
	}
	// 生产配置自检：配置了数据库说明这是长期运行的实例，验证码邮件写日志、
	// 验证码与匿名统计密钥缺失都会在重启或日志泄露时出问题，启动直接拒绝。
	if cfg.DatabaseURL != "" {
		if cfg.MailLog {
			errs = append(errs, errors.New("ZHIXIN_MAIL_LOG must be 0 when ZHIXIN_DATABASE_URL is set: verification codes must not be written to logs"))
		}
		if cfg.CodeSecret == "" {
			errs = append(errs, errors.New("ZHIXIN_CODE_SECRET is required when ZHIXIN_DATABASE_URL is set: codes would stop working after a restart"))
		}
		if cfg.TelemetrySecret == "" {
			errs = append(errs, errors.New("ZHIXIN_TELEMETRY_SECRET is required when ZHIXIN_DATABASE_URL is set: install hashes would change on restart"))
		}
	}
	appID := get("ZHIXIN_ALIPAY_APP_ID", "")
	privateKey := get("ZHIXIN_ALIPAY_PRIVATE_KEY", "")
	publicKey := get("ZHIXIN_ALIPAY_PUBLIC_KEY", "")
	if appID != "" || privateKey != "" || publicKey != "" {
		gateway, err := payment.NewGateway(appID, privateKey, publicKey)
		if err != nil {
			errs = append(errs, err)
		}
		cfg.Alipay = gateway
	}

	// 即刻收直连沿用同一个支付宝应用的应用凭证：网关、RSA2 签名与公共参数相同，
	// 商品 ID 从「即刻收」小程序商品详情复制，应用不能自己生成（ADR-0067）。
	// 没有商品 ID 表示不卖积分包。
	productID := strings.TrimSpace(get("ZHIXIN_NOWPAY_PRODUCT_ID", ""))
	if productID != "" {
		nowPay, err := parseNowPay(get, productID)
		if err != nil {
			errs = append(errs, err)
		} else if cfg.Alipay == nil {
			errs = append(errs, errors.New("ZHIXIN_NOWPAY_PRODUCT_ID 需要同一套 ZHIXIN_ALIPAY_* 应用凭证"))
		} else if cfg.DatabaseURL == "" {
			errs = append(errs, errors.New("即刻收收款需要 ZHIXIN_DATABASE_URL 保存购买入口与核销流水"))
		} else {
			cfg.NowPay = nowPay
		}
	}

	// 带 key 的上游地址由管理后台保存，地址在保存时校验（见 llmproxy.Admin）。
	if cfg.AccessTTL >= cfg.RefreshTTL && len(errs) == 0 {
		errs = append(errs, errors.New("ZHIXIN_ACCESS_TTL must be shorter than ZHIXIN_REFRESH_TTL"))
	}
	// 发布清单不合法时启动直接失败：更新检查是公测前必须可用的功能，清单写错
	// 却照常启动，客户端只会一直拿到空清单。
	releases, err := release.Load(cfg.ReleaseFile)
	if err != nil {
		errs = append(errs, err)
	}
	cfg.Releases = releases
	return cfg, errors.Join(errs...)
}

// emailDomainPattern 是允许配置的邮箱域名形状：至少两段，每段 1 至 63 个
// 字母、数字或连字符，且不以连字符开头或结尾。注册按 @ 之后的部分精确匹配，
// 子域不会因为父域在清单里而放行。
var emailDomainPattern = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$`)

// parseRegisterEmailDomains 解析注册允许的邮箱域名清单。值可以带前导 @，
// 大小写不敏感；* 表示不限制。清单一律小写，便于与服务层规范化之后的邮箱
// 比较。
func parseRegisterEmailDomains(raw string) ([]string, error) {
	raw = strings.ToLower(strings.TrimSpace(raw))
	if raw == "*" {
		return nil, nil
	}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		domain := strings.TrimPrefix(strings.TrimSpace(part), "@")
		if len(domain) > 253 || !emailDomainPattern.MatchString(domain) {
			return nil, fmt.Errorf("ZHIXIN_REGISTER_EMAIL_DOMAINS: %q 不是邮箱域名，例如 bupt.cn；不限制时写 *", part)
		}
		out = append(out, domain)
	}
	return out, nil
}

// parseTrustedProxies 解析反向代理地址与网段。只接受单地址或带前缀长度的
// 网段；不允许信任全部地址，否则客户端自己写 X-Forwarded-For 就能换一个
// 限流桶，配置等于没配。
func parseTrustedProxies(raw string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		var prefix netip.Prefix
		if strings.Contains(part, "/") {
			p, err := netip.ParsePrefix(part)
			if err != nil {
				return nil, fmt.Errorf("ZHIXIN_TRUSTED_PROXIES: %q 不是地址或网段: %w", part, err)
			}
			prefix = p.Masked()
		} else {
			addr, err := netip.ParseAddr(part)
			if err != nil {
				return nil, fmt.Errorf("ZHIXIN_TRUSTED_PROXIES: %q 不是地址或网段: %w", part, err)
			}
			addr = addr.Unmap()
			prefix = netip.PrefixFrom(addr, addr.BitLen())
		}
		if prefix.Bits() == 0 {
			return nil, fmt.Errorf("ZHIXIN_TRUSTED_PROXIES: %q 信任全部地址，拒绝", part)
		}
		out = append(out, prefix)
	}
	return out, nil
}

// smtpHost 从 host:port 取主机名；解析不了时原样返回，交给回环判断处理。
func smtpHost(addr string) string {
	if host, _, err := net.SplitHostPort(addr); err == nil {
		return host
	}
	return addr
}

// isLoopbackHost 判断主机名是否指向本机。localhost 与回环地址都算本机；
// 空主机名不算，宁可拒绝也不把带凭据的连接当成联调。
func isLoopbackHost(host string) bool {
	host = strings.TrimSpace(strings.Trim(host, "[]"))
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return false
	}
	return addr.Unmap().IsLoopback()
}
