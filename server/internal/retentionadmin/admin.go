// Package retentionadmin 是管理后台的留存视图：GET /admin/v1/retention。
//
// 它只读：数据来自 retention.Reader（install_active 与 user_active），管理令牌
// 由 internal/admin.Middleware 校验。公开的 POST /v1/telemetry/active 仍然只写
// 不读，两个方向分开，避免把后台视图暴露成公开接口。取舍见 ADR-0080。
package retentionadmin

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
	"github.com/BUPT521/zhixin/server/internal/retention"
)

// dayLayout 与服务端其余地方表示自然日的格式一致。
const dayLayout = "2006-01-02"

// Admin 承载留存视图的处理器。装配处传进来的 Reporter 决定时区与"今天"，这里
// 只做参数校验与格式转换。
type Admin struct {
	reporter *retention.Reporter
	log      *slog.Logger
}

func New(reporter *retention.Reporter, log *slog.Logger) *Admin {
	return &Admin{reporter: reporter, log: log}
}

// Report 返回区间内的每日活跃与按首次出现日分组的留存。天数沿用页面能选的
// 范围，越界与存储故障都返回 problem 体，页面据此显示原因而不是空白。
func (a *Admin) Report(w http.ResponseWriter, r *http.Request, params api.GetAdminV1RetentionParams) {
	days := retention.ReportDefaultDays
	if params.Days != nil {
		days = *params.Days
	}
	report, err := a.reporter.Report(r.Context(), days)
	switch {
	case errors.Is(err, retention.ErrInvalidRange):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			fmt.Sprintf("days: 1 to %d", retention.ReportMaxDays))
		return
	case err != nil:
		httpx.WriteInternal(w, r, a.log, err)
		return
	}
	out := api.AdminRetentionReport{
		Timezone: report.Timezone,
		Days:     report.Days,
		Daily:    make([]api.AdminRetentionDay, 0, len(report.Daily)),
		Cohorts:  make([]api.AdminRetentionCohort, 0, len(report.Cohorts)),
	}
	for _, day := range report.Daily {
		date, err := time.Parse(dayLayout, day.Day)
		if err != nil {
			httpx.WriteInternal(w, r, a.log, fmt.Errorf("parse retention day %q: %w", day.Day, err))
			return
		}
		out.Daily = append(out.Daily, api.AdminRetentionDay{
			Day: openapi_types.Date{Time: date}, Installs: day.Installs, Users: day.Users,
		})
	}
	for _, cohort := range report.Cohorts {
		date, err := time.Parse(dayLayout, cohort.FirstDay)
		if err != nil {
			httpx.WriteInternal(w, r, a.log, fmt.Errorf("parse retention cohort %q: %w", cohort.FirstDay, err))
			return
		}
		out.Cohorts = append(out.Cohorts, api.AdminRetentionCohort{
			FirstDay: openapi_types.Date{Time: date}, Installs: cohort.Installs,
			Returned7d: cohort.Returned7d, Returned28d: cohort.Returned28d,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}
