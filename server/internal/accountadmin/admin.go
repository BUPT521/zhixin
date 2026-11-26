// Package accountadmin 是管理后台的账号管理：列出与搜索账号、注销账号，以及
// 调整单个账号的每日模型额度。
//
// 账号与登录方式由 auth 存储提供，额度由 llmproxy 的额度存储提供，注销复用
// auth.Service 的账号清理；这里只做管理接口的校验、分页与视图组装，不重新实现
// 额度判定或账号删除。管理令牌由 internal/admin 的中间件校验。
package accountadmin

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/oapi-codegen/runtime/types"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/llmproxy"
)

const (
	defaultLimit = 20
	maxLimit     = 100
	maxOffset    = 100000
	maxQuery     = 254
	maxNote      = 200
	// maxCharges 是后台详情里列出的最近核销流水条数；流水只用于对账，不做完整
	// 翻页，需要看更早的流水时按运维手册查库。
	maxCharges = 5
	// pointsQueryTimeout 是“刷新余额”等即刻收一次查询的上限，与核销队列里的余额
	// 刷新同一量级；超时按即刻收不可用返回，副本保持原值。
	pointsQueryTimeout = 8 * time.Second
)

// AccountStore 是账号管理需要的 auth 存储子集。账号列表与管理接口都不看密码，
// 但复用 auth.Store 的实现，避免另一套账号索引。
type AccountStore interface {
	ListAccounts(ctx context.Context, query string, limit, offset int) ([]auth.AccountRecord, int, error)
	UserByID(ctx context.Context, id string) (auth.User, error)
	Identities(ctx context.Context, userID string) ([]auth.Identity, error)
}

// Admin 承载 /admin/v1/accounts 下的处理器。
type Admin struct {
	accounts AccountStore
	quota    llmproxy.Quota
	delete   func(ctx context.Context, userID string) error
	// chatDefault 与 embeddingDefault 是配置里的默认每日额度，没有覆盖值时
	// 响应与页面按它们显示“生效额度”。
	chatDefault      int64
	embeddingDefault int64
	loc              *time.Location
	now              func() time.Time
	log              *slog.Logger
	maxJSON          int64
}

// New 组装账号管理接口。del 由 server.Build 注入 auth.Service 的注销方法。
func New(accounts AccountStore, quota llmproxy.Quota, del func(context.Context, string) error,
	chatDefault, embeddingDefault int64, loc *time.Location, log *slog.Logger, maxJSON int64) *Admin {
	return &Admin{
		accounts:         accounts,
		quota:            quota,
		delete:           del,
		chatDefault:      chatDefault,
		embeddingDefault: embeddingDefault,
		loc:              loc,
		now:              time.Now,
		log:              log,
		maxJSON:          maxJSON,
	}
}

// List 列出与搜索账号。分页参数越界按 invalid_request 拒绝，而不是悄悄截断：
// 页面翻页时传错位置应当看得见。
func (a *Admin) List(w http.ResponseWriter, r *http.Request, params api.GetAdminV1AccountsParams) {
	limit := defaultLimit
	if params.Limit != nil {
		limit = *params.Limit
	}
	if limit < 1 || limit > maxLimit {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "limit: 1 to 100")
		return
	}
	offset := 0
	if params.Offset != nil {
		offset = *params.Offset
	}
	if offset < 0 || offset > maxOffset {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "offset: 0 to 100000")
		return
	}
	query := strings.TrimSpace(deref(params.Query, ""))
	if utf8.RuneCountInString(query) > maxQuery {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "query is too long")
		return
	}
	records, total, err := a.accounts.ListAccounts(r.Context(), query, limit, offset)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	ids := make([]string, 0, len(records))
	for _, record := range records {
		ids = append(ids, record.User.ID)
	}
	overrides, err := a.quota.QuotaOverrides(r.Context(), ids)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	data := make([]api.AdminAccount, 0, len(records))
	for _, record := range records {
		data = append(data, a.accountView(record, overrides[record.User.ID]))
	}
	httpx.WriteJSON(w, http.StatusOK, api.AdminAccountList{
		Data: data, Total: int64(total), Limit: limit, Offset: offset,
	})
}

// Get 读取一个账号的登录方式、额度、今日已结算用量与积分视图。用量与积分只读，
// 不推进任何计数，也不调用即刻收。
func (a *Admin) Get(w http.ResponseWriter, r *http.Request, id string) {
	record, ok := a.load(w, r, id)
	if !ok {
		return
	}
	override, err := a.override(r.Context(), id)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	now := a.now().In(a.loc)
	usage, err := a.usage(r.Context(), id, now)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	points, err := a.pointsView(r.Context(), id, now.Format(time.DateOnly))
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	view := a.accountView(record, override)
	view.Usage = &usage
	view.Points = points
	httpx.WriteJSON(w, http.StatusOK, view)
}

// RefreshPoints 同步查一次这个账号的积分余额并覆盖本地副本，返回刷新后的积分视图。
// 积分是钱：后台只提供查看与刷新，不提供补分、扣分或退款，核销流水也只读。
func (a *Admin) RefreshPoints(w http.ResponseWriter, r *http.Request, id string) {
	if _, ok := a.loadUser(w, r, id); !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), pointsQueryTimeout)
	defer cancel()
	enabled, err := a.quota.RefreshPoints(ctx, id)
	if err != nil {
		a.log.Warn("refresh the nowpay balance", "user_id", id, "error", err)
		httpx.WriteProblem(w, r, http.StatusBadGateway, httpx.CodeUpstreamFailed,
			"query the points balance from the payment provider")
		return
	}
	if !enabled {
		httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict,
			"points purchases are not enabled on this instance")
		return
	}
	view, err := a.pointsView(r.Context(), id, a.now().In(a.loc).Format(time.DateOnly))
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}

// PutQuota 整体替换一个账号的额度覆盖值。两项都为空且没有备注时等同于清除，
// 与数据库里不留一条空覆盖行的处理一致。
func (a *Admin) PutQuota(w http.ResponseWriter, r *http.Request, id string) {
	if _, ok := a.loadUser(w, r, id); !ok {
		return
	}
	var in api.PutAdminV1AccountsIdQuotaJSONRequestBody
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	note := strings.TrimSpace(deref(in.Note, ""))
	if utf8.RuneCountInString(note) > maxNote {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "note is too long")
		return
	}
	for _, value := range []*int64{in.DailyTokens, in.EmbeddingDailyTokens} {
		if value != nil && *value < 1 {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "daily_tokens and embedding_daily_tokens: at least 1, or null for the instance default")
			return
		}
	}
	if err := a.quota.SetQuotaOverride(r.Context(), id, in.DailyTokens, in.EmbeddingDailyTokens, note); err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	record, ok := a.load(w, r, id)
	if !ok {
		return
	}
	override, err := a.override(r.Context(), id)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, a.accountView(record, override))
}

// DeleteQuota 清除覆盖行，账号回到实例默认额度；没有覆盖行时同样返回 204。
func (a *Admin) DeleteQuota(w http.ResponseWriter, r *http.Request, id string) {
	if _, ok := a.loadUser(w, r, id); !ok {
		return
	}
	if err := a.quota.ClearQuotaOverride(r.Context(), id); err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// DeleteAccount 注销账号。请求体里的 user_id 必须与路径一致：管理页与脚本都把
// 编号再提交一次，编号看错时不会删掉另一个账号。清理与账号本人删号相同。
func (a *Admin) DeleteAccount(w http.ResponseWriter, r *http.Request, id string) {
	var in api.DeleteAdminV1AccountsIdJSONRequestBody
	if !httpx.DecodeJSON(w, r, a.maxJSON, &in) {
		return
	}
	if strings.TrimSpace(in.UserId) != id {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "user_id must match the path")
		return
	}
	if err := a.delete(r.Context(), id); err != nil {
		if errors.Is(err, auth.ErrNotFound) {
			httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
			return
		}
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *Admin) loadUser(w http.ResponseWriter, r *http.Request, id string) (auth.User, bool) {
	user, err := a.accounts.UserByID(r.Context(), id)
	if errors.Is(err, auth.ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return auth.User{}, false
	}
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return auth.User{}, false
	}
	return user, true
}

func (a *Admin) load(w http.ResponseWriter, r *http.Request, id string) (auth.AccountRecord, bool) {
	user, ok := a.loadUser(w, r, id)
	if !ok {
		return auth.AccountRecord{}, false
	}
	identities, err := a.accounts.Identities(r.Context(), id)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return auth.AccountRecord{}, false
	}
	return auth.AccountRecord{User: user, Identities: identities}, true
}

func (a *Admin) override(ctx context.Context, id string) (llmproxy.QuotaOverride, error) {
	overrides, err := a.quota.QuotaOverrides(ctx, []string{id})
	if err != nil {
		return llmproxy.QuotaOverride{}, err
	}
	return overrides[id], nil
}

// usage 按服务端时区取今天的已结算用量；在途预留不计入，页面据此判断今天的
// 消耗而不是此刻的临时占用。
func (a *Admin) usage(ctx context.Context, id string, now time.Time) (api.AdminAccountUsage, error) {
	day := now.Format(time.DateOnly)
	chat, err := a.quota.Used(ctx, id, day, llmproxy.KindChat)
	if err != nil {
		return api.AdminAccountUsage{}, err
	}
	embedding, err := a.quota.Used(ctx, id, day, llmproxy.KindEmbedding)
	if err != nil {
		return api.AdminAccountUsage{}, err
	}
	return api.AdminAccountUsage{
		Day: types.Date{Time: now}, ChatTokens: chat, EmbeddingTokens: embedding,
	}, nil
}

// pointsView 组装积分视图：今天已核销、可用积分、副本快照时刻与最近几条流水。
// 没有开通收款时三项都为空，页面据此说明这个实例不卖积分；开通了收款但账号还没有
// 副本时只给已核销积分，可用积分等副本同步之后再显示，不把缺失写成零（ADR-0073）。
func (a *Admin) pointsView(ctx context.Context, id, day string) (*api.AdminAccountPoints, error) {
	points, err := a.quota.Points(ctx, id, day)
	if err != nil {
		return nil, err
	}
	view := &api.AdminAccountPoints{
		Enabled: points.ChargedKnown, ChargedToday: points.Charged,
		Charges: []api.AdminPointCharge{},
	}
	if points.RemainingKnown {
		remaining := points.Remaining
		view.Remaining = &remaining
	}
	if !points.SyncedAt.IsZero() {
		synced := points.SyncedAt
		view.SyncedAt = &synced
	}
	if !view.Enabled {
		return view, nil
	}
	charges, err := a.quota.PointCharges(ctx, id, maxCharges)
	if err != nil {
		return nil, err
	}
	for _, charge := range charges {
		view.Charges = append(view.Charges, api.AdminPointCharge{
			Id: charge.ID, Day: types.Date{Time: charge.Day}, Points: charge.Points,
			BilledTokens: charge.BilledTokens, Status: api.AdminPointChargeStatus(charge.Status),
			CreatedAt: charge.CreatedAt, UpdatedAt: charge.UpdatedAt,
		})
	}
	return view, nil
}

// accountView 把账号、登录方式与覆盖行合成响应。生效额度优先取覆盖值，没有
// 覆盖时用实例默认值；覆盖项本身只在有调整时返回。
func (a *Admin) accountView(record auth.AccountRecord, override llmproxy.QuotaOverride) api.AdminAccount {
	identities := make([]api.AdminAccountIdentity, 0, len(record.Identities))
	for _, identity := range record.Identities {
		identities = append(identities, api.AdminAccountIdentity{
			Kind:       identityKind(identity.Kind),
			Identifier: identity.Identifier,
			Verified:   !identity.VerifiedAt.IsZero(),
		})
	}
	quota := api.AdminAccountQuota{
		DailyTokens:                 effectiveLimit(override.DailyTokens, a.chatDefault),
		DefaultDailyTokens:          a.chatDefault,
		EmbeddingDailyTokens:        effectiveLimit(override.EmbeddingDailyTokens, a.embeddingDefault),
		DefaultEmbeddingDailyTokens: a.embeddingDefault,
		Note:                        override.Note,
	}
	if override.DailyTokens != nil {
		value := *override.DailyTokens
		quota.DailyTokensOverride = &value
	}
	if override.EmbeddingDailyTokens != nil {
		value := *override.EmbeddingDailyTokens
		quota.EmbeddingDailyTokensOverride = &value
	}
	if !override.UpdatedAt.IsZero() {
		updated := override.UpdatedAt
		quota.UpdatedAt = &updated
	}
	return api.AdminAccount{
		Id: record.User.ID, CreatedAt: record.User.CreatedAt,
		Identities: identities, Quota: quota,
	}
}

func effectiveLimit(override *int64, fallback int64) int64 {
	if override != nil {
		return *override
	}
	return fallback
}

// identityKind 把存储里的登录方式转成契约的取值。四种取值一一对应，以后加
// 新种类时直接透传，不会把它误标成邮箱。
func identityKind(kind string) api.IdentityKind {
	switch kind {
	case auth.KindEmail:
		return api.Email
	case auth.KindPhone:
		return api.Phone
	case auth.KindWechat:
		return api.Wechat
	default:
		return api.IdentityKind(kind)
	}
}

func deref[T any](value *T, fallback T) T {
	if value == nil {
		return fallback
	}
	return *value
}
