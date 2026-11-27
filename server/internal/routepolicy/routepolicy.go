// Package routepolicy 决定已匹配路由的横切规则：哪些操作公开、哪些要求 Bearer、
// 哪些上传按账号限流、哪些响应可以缓存。
//
// 规则一律以 net/http 的 r.Pattern 为键，而不是重新拼 r.URL.Path。生成的路由
// 处理器里，mux 已经把注册模式（例如 "GET /v1/me"）写进 r.Pattern：编码路径
// （/v1/%6de）先归一再匹配，HEAD 落到 GET 路由时同样是 "GET /v1/me"，所以这里
// 的默认拒绝不会被写法差异绕过。r.Pattern 为空说明没有匹配到契约路由，交给
// mux 的兜底 404，不在这里做判断。
package routepolicy

// publicOperations 显式列出 openapi.yaml 里声明 security: [] 的操作，写法与
// 生成代码注册的模式一致。除这些之外，只要 r.Pattern 非空就要求 Bearer；新增
// 公开接口必须同时改这里与契约，否则会被默认拒绝，或者被契约测试发现两边漂移。
var publicOperations = []string{
	"GET /healthz",
	"GET /readyz",
	"POST /v1/auth/register",
	"POST /v1/auth/login",
	"POST /v1/auth/refresh",
	"POST /v1/auth/password/forgot",
	"POST /v1/auth/password/reset",
	"GET /v1/app/releases",
	"POST /v1/telemetry/active",
	"POST /v1/feedback",
}

// Spool identifies uploads that reserve space for a temporary file.
type Spool uint8

const (
	NoSpool Spool = iota
	BackupSpool
	AttachmentSpool
)

// CloudWrite defines the protections for a write to an account's cloud data.
type CloudWrite struct {
	Upload    bool
	Spool     Spool
	Exclusive bool
}

var cloudWrites = map[string]CloudWrite{
	"POST /v1/backups":        {Upload: true, Spool: BackupSpool},
	"PUT /v1/blobs/{sha256}":  {Upload: true, Spool: AttachmentSpool},
	"POST /v1/sync/commits":   {Upload: true},
	"PUT /v1/sync/snapshot":   {},
	"PUT /v1/sync/refs":       {},
	"PUT /v1/sync/devices":    {},
	"DELETE /v1/backups/{id}": {},
	"DELETE /v1/cloud":        {Exclusive: true},
	"DELETE /v1/sync/commits": {Exclusive: true},
	"DELETE /v1/backups":      {Exclusive: true},
	"DELETE /v1/me":           {Exclusive: true},
}

// CloudWritePolicy reports whether a matched operation takes part in cloud
// deletion exclusion and which upload limits apply to it.
func CloudWritePolicy(pattern string) (CloudWrite, bool) {
	policy, ok := cloudWrites[pattern]
	return policy, ok
}

// keyOperations 是模型代理密钥可以访问的路由：只有模型调用与它们的元数据。
// 密钥不持有学习数据，所以同步、备份、附件与账号管理都不在其中；密钥访问其余
// 受保护路由时回 403 key_scope_denied（ADR-0063）。
var keyOperations = []string{
	"POST /v1/llm/responses",
	"POST /v1/llm/embeddings",
	"POST /v1/llm/embeddings/lookup",
	"GET /v1/llm/models",
	"GET /v1/llm/quota",
}

// cacheableOperations 是明确可以缓存的公开响应，值是 max-age 的秒数。目前只有
// 发布清单：它在服务端启动时读入，只有重启才会变化，短缓存能减少重复请求，
// 又不至于让新版本久等。
var cacheableOperations = map[string]int{
	"GET /v1/app/releases": 60,
}

// PublicOperations 返回公开操作的副本，供契约测试与文档核对。
func PublicOperations() []string {
	return append([]string(nil), publicOperations...)
}

// IsPublic 报告这条已匹配的路由是否公开。
func IsPublic(pattern string) bool { return contains(publicOperations, pattern) }

// RequiresAuth 报告已匹配的路由是否要求 Bearer。没有匹配到路由时 r.Pattern 为空，
// 这时不该在这里拒绝，否则 mux 的 404 会变成 401，客户端也拿不到 problem 体。
func RequiresAuth(pattern string) bool { return pattern != "" && !IsPublic(pattern) }

// IsUpload 报告这条已匹配的路由是否属于按账号限流的上传。
func IsUpload(pattern string) bool { return cloudWrites[pattern].Upload }

// AllowsKey 报告这条已匹配的路由是否接受模型代理密钥。
func AllowsKey(pattern string) bool { return contains(keyOperations, pattern) }

// KeyOperations 返回密钥可以访问的操作副本，供契约测试核对。
func KeyOperations() []string {
	return append([]string(nil), keyOperations...)
}

// CacheSeconds 返回这条路由允许的缓存秒数；第二个返回值为假表示保持默认的
// no-store。
func CacheSeconds(pattern string) (int, bool) {
	seconds, ok := cacheableOperations[pattern]
	return seconds, ok
}

func contains(list []string, pattern string) bool {
	for _, item := range list {
		if item == pattern {
			return true
		}
	}
	return false
}
