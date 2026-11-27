// Package feedbackadmin 是管理后台的反馈查看：按提交时间分页列出、读取一条
// 反馈的诊断摘要、删除一条反馈。
//
// 公开的反馈接口只写不读（ADR-0025），后台的读取入口见 ADR-0079。反馈不绑定
// 账号，这里的接口也不返回任何账号关联；管理令牌由 internal/admin 的中间件
// 校验。
package feedbackadmin

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/adminlist"
	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/deref"
	"github.com/BUPT521/zhixin/server/internal/feedback"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Store 是反馈管理需要的存储子集，由 feedback.MemoryStore 与 PostgreSQL 实现
// 提供；公开提交与保留期清理仍走 feedback.Store。
type Store interface {
	ListFeedback(ctx context.Context, query string, limit, offset int) ([]feedback.ListItem, int, error)
	FeedbackByID(ctx context.Context, id string) (feedback.Item, error)
	DeleteFeedback(ctx context.Context, id string) error
}

// Admin 承载 /admin/v1/feedback 下的处理器。
type Admin struct {
	store Store
	log   *slog.Logger
}

// New 组装反馈管理接口。
func New(store Store, log *slog.Logger) *Admin {
	return &Admin{store: store, log: log}
}

// List 列出与搜索反馈。分页参数越界按 invalid_request 拒绝，而不是悄悄截断；
// 与账号列表同一口径。
func (a *Admin) List(w http.ResponseWriter, r *http.Request, params api.GetAdminV1FeedbackParams) {
	limit, err := adminlist.Limit(params.Limit)
	if err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}
	offset, err := adminlist.Offset(params.Offset)
	if err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}
	query := strings.TrimSpace(deref.Value(params.Query, ""))
	if err := adminlist.Query(query); err != nil {
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, err.Error())
		return
	}
	items, total, err := a.store.ListFeedback(r.Context(), query, limit, offset)
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	data := make([]api.AdminFeedback, 0, len(items))
	for _, item := range items {
		data = append(data, api.AdminFeedback{
			Id:             item.ID,
			CreatedAt:      item.CreatedAt,
			Content:        item.Content,
			Contact:        item.Contact,
			AppVersion:     item.AppVersion,
			Platform:       item.Platform,
			HasDiagnostics: item.HasDiagnostics,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, api.AdminFeedbackList{
		Data: data, Total: int64(total), Limit: limit, Offset: offset,
	})
}

// Get 读取一条反馈的正文与诊断摘要。读取不改变任何数据，也不推进保留期。
func (a *Admin) Get(w http.ResponseWriter, r *http.Request, id string) {
	item, err := a.store.FeedbackByID(r.Context(), id)
	if errors.Is(err, feedback.ErrNotFound) {
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, api.AdminFeedbackDetail{
		Id:          item.ID,
		CreatedAt:   item.CreatedAt,
		Content:     item.Content,
		Contact:     item.Contact,
		AppVersion:  item.AppVersion,
		Platform:    item.Platform,
		Diagnostics: item.Diagnostics,
	})
}

// Delete 删除一条反馈。删除不可恢复，保留期到期的行仍由每日清理处理；编号不
// 存在时返回 404，重试同一个请求不会得到第二次成功。
func (a *Admin) Delete(w http.ResponseWriter, r *http.Request, id string) {
	if err := a.store.DeleteFeedback(r.Context(), id); err != nil {
		if errors.Is(err, feedback.ErrNotFound) {
			httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "")
			return
		}
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
