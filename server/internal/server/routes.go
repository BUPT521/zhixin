package server

import (
	"context"
	"log/slog"
	"strings"

	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// routes 把生成代码里的路由接到各业务包的处理器上（ADR-0015 第 4 条）。
//
// 这里只做转发，不看请求内容、不写响应：解码、校验、problem+json 与状态码仍在
// 各处理器里。契约改了而这里没跟上时编译失败。
type routes struct {
	auth    *auth.Handler
	sync    *syncsvc.Handler
	backups *backup.Handler
	blobs   *blobs.Handler
	llm     *llmproxy.Proxy

	schemaVersion int
	ready         func(ctx context.Context) error
}

var _ api.ServerInterface = routes{}

func (rt routes) GetHealthz(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, api.Health{Status: api.Ok})
}

func (rt routes) GetReadyz(w http.ResponseWriter, r *http.Request) {
	if rt.ready != nil {
		if err := rt.ready(r.Context()); err != nil {
			httpx.WriteProblem(w, r, http.StatusServiceUnavailable, httpx.CodeUnavailable, "a dependency is not reachable")
			return
		}
	}
	httpx.WriteJSON(w, http.StatusOK, api.Ready{Status: api.ReadyStatusReady, SchemaVersion: rt.schemaVersion})
}

func (rt routes) PostV1AuthRegister(w http.ResponseWriter, r *http.Request) { rt.auth.Register(w, r) }
func (rt routes) PostV1AuthLogin(w http.ResponseWriter, r *http.Request)    { rt.auth.Login(w, r) }
func (rt routes) PostV1AuthRefresh(w http.ResponseWriter, r *http.Request)  { rt.auth.Refresh(w, r) }
func (rt routes) PostV1AuthLogout(w http.ResponseWriter, r *http.Request)   { rt.auth.Logout(w, r) }
func (rt routes) GetV1Me(w http.ResponseWriter, r *http.Request)            { rt.auth.Me(w, r) }
func (rt routes) DeleteV1Me(w http.ResponseWriter, r *http.Request)         { rt.auth.DeleteMe(w, r) }

func (rt routes) GetV1SyncHead(w http.ResponseWriter, r *http.Request) { rt.sync.Head(w, r) }
func (rt routes) GetV1SyncCommits(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	rt.sync.Pull(w, r, params)
}
func (rt routes) PostV1SyncCommits(w http.ResponseWriter, r *http.Request) {
	rt.sync.Push(w, r)
}

func (rt routes) GetV1BlobsSha256(w http.ResponseWriter, r *http.Request, sha256 string) {
	rt.blobs.Get(w, r, sha256)
}
func (rt routes) HeadV1BlobsSha256(w http.ResponseWriter, r *http.Request, sha256 string) {
	rt.blobs.Head(w, r, sha256)
}
func (rt routes) PutV1BlobsSha256(w http.ResponseWriter, r *http.Request, sha256 string) {
	rt.blobs.Put(w, r, sha256)
}

func (rt routes) GetV1Backups(w http.ResponseWriter, r *http.Request) { rt.backups.List(w, r) }
func (rt routes) PostV1Backups(w http.ResponseWriter, r *http.Request, params api.PostV1BackupsParams) {
	rt.backups.Upload(w, r, params)
}
func (rt routes) GetV1BackupsId(w http.ResponseWriter, r *http.Request, id string) {
	rt.backups.Download(w, r, id)
}
func (rt routes) DeleteV1BackupsId(w http.ResponseWriter, r *http.Request, id string) {
	rt.backups.Delete(w, r, id)
}

func (rt routes) GetV1LlmModels(w http.ResponseWriter, r *http.Request) { rt.llm.Models(w, r) }
func (rt routes) GetV1LlmQuota(w http.ResponseWriter, r *http.Request)  { rt.llm.QuotaStatus(w, r) }
func (rt routes) PostV1LlmChatCompletions(w http.ResponseWriter, r *http.Request) {
	rt.llm.Chat(w, r)
}

// securedRoutes 是契约里要求 Bearer 的路径，写法与 openapi.yaml 的分段一致：
// `{name}` 匹配任意一段。只列需要鉴权的；公开路径与契约之外的路径都直接放行，
// 后者仍由 mux 的兜底处理器返回 404。
//
// 这张表放在代码里而不是从生成结果读取，是因为 oapi-codegen 的中间件拿不到当前
// 操作的 security 声明；契约增删接口时要同时改这里。
var securedRoutes = []struct {
	method  string
	pattern string
}{
	{"POST", "/v1/auth/logout"},
	{"GET", "/v1/me"},
	{"DELETE", "/v1/me"},
	{"GET", "/v1/sync/head"},
	{"GET", "/v1/sync/commits"},
	{"POST", "/v1/sync/commits"},
	{"HEAD", "/v1/blobs/{sha256}"},
	{"GET", "/v1/blobs/{sha256}"},
	{"PUT", "/v1/blobs/{sha256}"},
	{"GET", "/v1/backups"},
	{"POST", "/v1/backups"},
	{"GET", "/v1/backups/{id}"},
	{"DELETE", "/v1/backups/{id}"},
	{"GET", "/v1/llm/models"},
	{"GET", "/v1/llm/quota"},
	{"POST", "/v1/llm/chat/completions"},
}

// matchPath 比较契约写法与实际路径：{name} 匹配一段非空路径。
func matchPath(pattern, path string) bool {
	want := strings.Split(strings.Trim(pattern, "/"), "/")
	got := strings.Split(strings.Trim(path, "/"), "/")
	if len(want) != len(got) {
		return false
	}
	for i, seg := range want {
		if strings.HasPrefix(seg, "{") && strings.HasSuffix(seg, "}") {
			if got[i] == "" {
				return false
			}
			continue
		}
		if seg != got[i] {
			return false
		}
	}
	return true
}

// needsAuth 报告这条请求是否落在需要 Bearer 的路由上。
func needsAuth(method, path string) bool {
	for _, rt := range securedRoutes {
		if rt.method == method && matchPath(rt.pattern, path) {
			return true
		}
	}
	return false
}

// withAuth 给需要鉴权的路由加上 Bearer 校验，并把调用者放进请求上下文。
func withAuth(next http.Handler, svc *auth.Service, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !needsAuth(r.Method, r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin"`)
			httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "missing bearer token")
			return
		}
		p, err := svc.Authenticate(r.Context(), token)
		if err != nil {
			w.Header().Set("WWW-Authenticate", `Bearer realm="zhixin", error="invalid_token"`)
			httpx.WriteProblem(w, r, http.StatusUnauthorized, httpx.CodeUnauthorized, "access token is invalid or expired")
			return
		}
		next.ServeHTTP(w, r.WithContext(auth.WithPrincipal(r.Context(), p)))
	})
}
