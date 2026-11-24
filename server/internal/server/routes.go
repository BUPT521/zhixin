package server

import (
	"context"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/backup"
	"github.com/BUPT521/zhixin/server/internal/blobs"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
	"github.com/BUPT521/zhixin/server/internal/payment"
	"github.com/BUPT521/zhixin/server/internal/release"
	"github.com/BUPT521/zhixin/server/internal/retention"
	"github.com/BUPT521/zhixin/server/internal/syncsvc"
)

// routes 把生成代码里的路由接到各业务包的处理器上（ADR-0015 第 4 条）。
//
// 这里只做转发，不看请求内容、不写响应：解码、校验、problem+json 与状态码仍在
// 各处理器里，鉴权在 auth.Middleware。契约改了而这里没跟上时编译失败。
type routes struct {
	auth      *auth.Handler
	sync      *syncsvc.Handler
	backups   *backup.Handler
	blobs     *blobs.Handler
	llm       *llmproxy.Proxy
	payments  *payment.Handler
	llmAdmin  *llmproxy.Admin
	feedback  *feedback.Handler
	release   *release.Handler
	retention *retention.Handler

	// cloud 清空账号的云端数据；由 server.New 注入，见 DeleteV1Cloud。
	cloud func(w http.ResponseWriter, r *http.Request)

	schemaVersion int
	ready         func(ctx context.Context) error
}

var _ api.ServerInterface = routes{}

func (rt routes) GetHealthz(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, api.Health{Status: api.HealthStatusOk})
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
func (rt routes) PostV1MeIdentitiesIdVerification(w http.ResponseWriter, r *http.Request, id string) {
	rt.auth.RequestIdentityVerification(w, r, id)
}
func (rt routes) PostV1MeIdentitiesIdVerificationConfirm(w http.ResponseWriter, r *http.Request, id string) {
	rt.auth.ConfirmIdentityVerification(w, r, id)
}
func (rt routes) PostV1AuthPasswordForgot(w http.ResponseWriter, r *http.Request) {
	rt.auth.ForgotPassword(w, r)
}
func (rt routes) PostV1AuthPasswordReset(w http.ResponseWriter, r *http.Request) {
	rt.auth.ResetPassword(w, r)
}
func (rt routes) GetV1Me(w http.ResponseWriter, r *http.Request)    { rt.auth.Me(w, r) }
func (rt routes) DeleteV1Me(w http.ResponseWriter, r *http.Request) { rt.auth.DeleteMe(w, r) }

// 模型代理的接入密钥（ADR-0063）：签发、列出与撤销都要求登录令牌，密钥本身
// 只能调用 /v1/llm 下的模型接口。
func (rt routes) GetV1MeApiKeys(w http.ResponseWriter, r *http.Request) {
	rt.auth.ListAPIKeys(w, r)
}
func (rt routes) PostV1MeApiKeys(w http.ResponseWriter, r *http.Request) {
	rt.auth.CreateAPIKey(w, r)
}
func (rt routes) DeleteV1MeApiKeysId(w http.ResponseWriter, r *http.Request, id string) {
	rt.auth.RevokeAPIKey(w, r, id)
}
func (rt routes) DeleteV1MeApiKeys(w http.ResponseWriter, r *http.Request) {
	rt.auth.RevokeAllAPIKeys(w, r)
}

// DeleteV1Cloud 清空账号的备份、提交序列、附件与遗留对象；装配由 server.New
// 注入，未装配时返回 501 而不是悄悄回 204。
func (rt routes) DeleteV1Cloud(w http.ResponseWriter, r *http.Request) {
	if rt.cloud == nil {
		httpx.WriteProblem(w, r, http.StatusNotImplemented, httpx.CodeNotImplemented, "cloud purge is not wired")
		return
	}
	if rt.auth.ConfirmPassword(w, r) {
		rt.cloud(w, r)
	}
}

func (rt routes) GetV1SyncHead(w http.ResponseWriter, r *http.Request, params api.GetV1SyncHeadParams) {
	rt.sync.Head(w, r, params)
}
func (rt routes) GetV1SyncCommits(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	rt.sync.Pull(w, r, params)
}
func (rt routes) PostV1SyncCommits(w http.ResponseWriter, r *http.Request, params api.PostV1SyncCommitsParams) {
	rt.sync.Push(w, r, params)
}
func (rt routes) DeleteV1SyncCommits(w http.ResponseWriter, r *http.Request) {
	if rt.auth.ConfirmPassword(w, r) {
		rt.sync.Reset(w, r)
	}
}
func (rt routes) GetV1SyncSnapshot(w http.ResponseWriter, r *http.Request) {
	rt.sync.Snapshot(w, r)
}
func (rt routes) PutV1SyncSnapshot(w http.ResponseWriter, r *http.Request, params api.PutV1SyncSnapshotParams) {
	rt.sync.RegisterSnapshot(w, r, params)
}
func (rt routes) GetV1SyncDevices(w http.ResponseWriter, r *http.Request, params api.GetV1SyncDevicesParams) {
	rt.sync.Devices(w, r, params)
}
func (rt routes) PutV1SyncDevices(w http.ResponseWriter, r *http.Request) {
	rt.sync.RenameDevice(w, r)
}
func (rt routes) GetV1SyncRefs(w http.ResponseWriter, r *http.Request) {
	rt.sync.Refs(w, r)
}
func (rt routes) PutV1SyncRefs(w http.ResponseWriter, r *http.Request) {
	rt.sync.PutRef(w, r)
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
func (rt routes) DeleteV1Backups(w http.ResponseWriter, r *http.Request) {
	if rt.auth.ConfirmPassword(w, r) {
		rt.backups.DeleteAll(w, r)
	}
}
func (rt routes) PostV1Backups(w http.ResponseWriter, r *http.Request, params api.PostV1BackupsParams) {
	rt.backups.Upload(w, r, params)
}
func (rt routes) GetV1BackupsId(w http.ResponseWriter, r *http.Request, id string) {
	rt.backups.Download(w, r, id)
}
func (rt routes) DeleteV1BackupsId(w http.ResponseWriter, r *http.Request, id string) {
	rt.backups.Delete(w, r, id)
}

func (rt routes) GetV1MeModelQuotaPurchases(w http.ResponseWriter, r *http.Request) {
	rt.payments.Overview(w, r)
}
func (rt routes) PostV1MeModelQuotaPurchases(w http.ResponseWriter, r *http.Request) {
	rt.payments.Checkout(w, r)
}
func (rt routes) GetV1MeModelQuotaPurchasesId(w http.ResponseWriter, r *http.Request, id string) {
	rt.payments.Status(w, r, id)
}
func (rt routes) PostV1PaymentsAlipayNotify(w http.ResponseWriter, r *http.Request) {
	rt.payments.Notify(w, r)
}

func (rt routes) GetV1LlmModels(w http.ResponseWriter, r *http.Request) { rt.llm.Models(w, r) }
func (rt routes) GetV1LlmQuota(w http.ResponseWriter, r *http.Request)  { rt.llm.QuotaStatus(w, r) }
func (rt routes) PostV1LlmResponses(w http.ResponseWriter, r *http.Request, params api.PostV1LlmResponsesParams) {
	rt.llm.Responses(w, r, llmproxy.RequestOptions{
		RoundBudgetMs: params.XZhixinRoundBudgetMs,
		SessionID:     params.XZhixinSessionId,
	})
}

func (rt routes) PostV1LlmEmbeddings(w http.ResponseWriter, r *http.Request, params api.PostV1LlmEmbeddingsParams) {
	rt.llm.Embeddings(w, r, params)
}
func (rt routes) PostV1LlmEmbeddingsLookup(w http.ResponseWriter, r *http.Request, params api.PostV1LlmEmbeddingsLookupParams) {
	rt.llm.EmbeddingLookup(w, r, params)
}

// 管理接口：管理令牌由 internal/admin.Middleware 校验，这里只转发。
func (rt routes) GetAdminV1Providers(w http.ResponseWriter, r *http.Request) {
	rt.llmAdmin.ListProviders(w, r)
}
func (rt routes) PostAdminV1Providers(w http.ResponseWriter, r *http.Request) {
	rt.llmAdmin.CreateProvider(w, r)
}
func (rt routes) PutAdminV1ProvidersId(w http.ResponseWriter, r *http.Request, id string) {
	rt.llmAdmin.PutProvider(w, r, id)
}
func (rt routes) DeleteAdminV1ProvidersId(w http.ResponseWriter, r *http.Request, id string) {
	rt.llmAdmin.DeleteProvider(w, r, id)
}
func (rt routes) PostAdminV1ProvidersIdTest(w http.ResponseWriter, r *http.Request, id string) {
	rt.llmAdmin.TestProvider(w, r, id)
}
func (rt routes) GetAdminV1Models(w http.ResponseWriter, r *http.Request) {
	rt.llmAdmin.ListModels(w, r)
}
func (rt routes) PostAdminV1Models(w http.ResponseWriter, r *http.Request) {
	rt.llmAdmin.CreateModel(w, r)
}
func (rt routes) GetAdminV1Usage(w http.ResponseWriter, r *http.Request, params api.GetAdminV1UsageParams) {
	rt.llmAdmin.Usage(w, r, params)
}
func (rt routes) PutAdminV1ModelsName(w http.ResponseWriter, r *http.Request, name string) {
	rt.llmAdmin.PutModel(w, r, name)
}
func (rt routes) DeleteAdminV1ModelsName(w http.ResponseWriter, r *http.Request, name string) {
	rt.llmAdmin.DeleteModel(w, r, name)
}
func (rt routes) PostAdminV1ModelsNameTest(w http.ResponseWriter, r *http.Request, name string, params api.PostAdminV1ModelsNameTestParams) {
	rt.llmAdmin.TestModel(w, r, name, params)
}

func (rt routes) GetV1AppReleases(w http.ResponseWriter, r *http.Request) { rt.release.Releases(w, r) }
func (rt routes) PostV1Feedback(w http.ResponseWriter, r *http.Request)   { rt.feedback.Submit(w, r) }
func (rt routes) PostV1TelemetryActive(w http.ResponseWriter, r *http.Request) {
	rt.retention.Report(w, r)
}
