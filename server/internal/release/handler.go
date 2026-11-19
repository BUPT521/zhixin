package release

import (
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler 提供 /v1/app/releases。清单在启动时读入，发布新版本之后改文件并重启
// 服务，与其他部署步骤相同；接口本身没有写入口，也不接受任何参数。
type Handler struct {
	entries []Entry
}

// NewHandler 用启动时读好的清单装配接口；没有清单时返回空数组。
func NewHandler(entries []Entry) *Handler {
	return &Handler{entries: entries}
}

func (h *Handler) Releases(w http.ResponseWriter, r *http.Request) {
	out := make([]api.Release, 0, len(h.entries))
	for _, e := range h.entries {
		out = append(out, entryJSON(e))
	}
	httpx.WriteJSON(w, http.StatusOK, api.ReleaseList{Releases: out})
}

// entryJSON 把清单里的一条转成契约类型，可选字段只在写了的时候出现，客户端
// 按字段是否存在决定显示什么，不显示空串。
func entryJSON(e Entry) api.Release {
	out := api.Release{
		Platform:  e.Platform,
		Version:   e.Version,
		Build:     e.Build,
		Url:       e.URL,
		Sha256:    e.SHA256,
		Signature: e.Signature,
	}
	if e.PublishedAt != "" {
		v := e.PublishedAt
		out.PublishedAt = &v
	}
	if e.Size > 0 {
		v := e.Size
		out.Size = &v
	}
	if e.MinVersion != "" {
		v := e.MinVersion
		out.MinVersion = &v
	}
	if e.Notes != "" {
		v := e.Notes
		out.Notes = &v
	}
	return out
}
