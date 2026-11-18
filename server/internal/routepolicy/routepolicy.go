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

// uploadOperations 是会把请求体先落到临时文件的写操作：备份与附件。它们按账号
// 限流，避免一个账号反复上传把磁盘写满。
var uploadOperations = []string{
	"POST /v1/backups",
	"PUT /v1/blobs/{sha256}",
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
func IsUpload(pattern string) bool { return contains(uploadOperations, pattern) }

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
