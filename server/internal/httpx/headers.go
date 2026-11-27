package httpx

import (
	"net/http"
	"strconv"
)

const (
	// cacheNoStore 是所有响应的默认缓存策略：账号数据、problem 体与 401 都不
	// 应该被浏览器、代理或中间层保存下来。
	cacheNoStore = "no-store"
	cacheHeader  = "Cache-Control"
)

// SecurityHeaders 给每个响应加统一的安全头：nosniff 阻止浏览器按内容猜类型，
// Cache-Control 默认 no-store。
//
// 默认值不能被处理器顺手覆盖：传给处理器的 w 被换成 cacheGuard，只有调用
// Cacheable 明确声明可缓存的响应才保留 public, max-age，其余响应在写响应头时
// 一律改回 no-store。这样“能不能缓存”只有一个入口，新增处理器不用记得设默认值，
// 也不会因为抄了一段 Header().Set 就把账号数据标成可缓存。
func SecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set(cacheHeader, cacheNoStore)
		next.ServeHTTP(&cacheGuard{ResponseWriter: w}, r)
	})
}

// Cacheable 把响应标记为可被客户端与中间层缓存 seconds 秒，只有对所有调用者
// 都相同、且确实适合缓存的公开响应才调用它。必须在写响应头之前调用；写完之后
// 再调用不会生效。
func Cacheable(w http.ResponseWriter, seconds int) {
	if seconds < 0 {
		seconds = 0
	}
	if guard, ok := w.(interface{ allowCache(int) }); ok {
		guard.allowCache(seconds)
		return
	}
	w.Header().Set(cacheHeader, "public, max-age="+strconv.Itoa(seconds))
}

// cacheGuard 在写出响应头之前落实默认的 no-store，只放过经 Cacheable 明确
// 允许缓存的那个响应。
type cacheGuard struct {
	http.ResponseWriter
	allowed bool
	wrote   bool
}

func (g *cacheGuard) allowCache(seconds int) {
	g.allowed = true
	g.Header().Set(cacheHeader, "public, max-age="+strconv.Itoa(seconds))
}

// start 在第一次写响应头之前调用：没有经 Cacheable 允许、或状态码不是 2xx 的
// 响应一律改回 no-store，避免把错误响应缓存成公开内容。
func (g *cacheGuard) start(code int) {
	g.wrote = true
	if g.allowed && code >= 200 && code < 300 {
		return
	}
	g.Header().Set(cacheHeader, cacheNoStore)
}

func (g *cacheGuard) WriteHeader(code int) {
	if !g.wrote {
		g.start(code)
	}
	g.ResponseWriter.WriteHeader(code)
}

func (g *cacheGuard) Write(b []byte) (int, error) {
	if !g.wrote {
		g.start(http.StatusOK)
	}
	return g.ResponseWriter.Write(b)
}

// SetPattern 把生成代码记录的注册模式转交给内层 ResponseWriter（访问日志的
// statusRecorder）。SecurityHeaders 夹在 RecordPattern 与访问日志之间，不实现
// 这个方法时 RecordPattern 的类型断言必然失败，访问日志只能靠外层请求上的
// r.Pattern 兜底（S19）。
func (g *cacheGuard) SetPattern(pattern string) {
	if rec, ok := g.ResponseWriter.(interface{ SetPattern(string) }); ok {
		rec.SetPattern(pattern)
	}
}

// Flush 让流式响应继续可用，并把默认响应头在第一次刷新之前写好。
func (g *cacheGuard) Flush() {
	if !g.wrote {
		g.start(http.StatusOK)
		g.ResponseWriter.WriteHeader(http.StatusOK)
	}
	if f, ok := g.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Unwrap 让 http.ResponseController 能找到底层的 ResponseWriter，请求体读期限
// 与流式响应的刷新都靠它穿透这一层。
func (g *cacheGuard) Unwrap() http.ResponseWriter { return g.ResponseWriter }
