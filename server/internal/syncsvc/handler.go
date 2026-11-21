package syncsvc

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
	"github.com/BUPT521/zhixin/server/internal/cloudpurge"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

// Handler exposes /v1/sync. It parses HTTP and maps service errors; validation
// and page bounds live in Service. Responses are the contract's generated
// types, so a field added to api/openapi.yaml reaches the client without a
// second definition here.
type Handler struct {
	svc      *Service
	log      *slog.Logger
	maxBytes int64
	// gate 在写数据之前问一次“这个账号是不是正在清除云端数据”；它由装配
	// 注入，没有注入时不拦请求。
	gate func(ctx context.Context, userID string) error
}

// NewHandler wires the handler.
func NewHandler(svc *Service, log *slog.Logger, maxBytes int64) *Handler {
	return &Handler{svc: svc, log: log, maxBytes: min(maxBytes, MaxPushBytes)}
}

// SetPurgeGate 注入清除期间的写拦截。gate 返回 cloudpurge.ErrPurging 时，
// Push、Reset 与快照登记回 409 并且不写数据；返回其它错误按 500 处理。装配时传
// cloudpurge.Service.Gate。
func (h *Handler) SetPurgeGate(gate func(ctx context.Context, userID string) error) {
	h.gate = gate
}

// allowWrite 在清除进行时写好 409 并返回 false，调用方据此直接返回。
func (h *Handler) allowWrite(w http.ResponseWriter, r *http.Request, userID string) bool {
	if h.gate == nil {
		return true
	}
	if err := h.gate(r.Context(), userID); err != nil {
		if errors.Is(err, cloudpurge.ErrPurging) {
			httpx.WriteProblem(w, r, http.StatusConflict, httpx.CodeConflict, "cloud purge in progress")
			return false
		}
		httpx.WriteInternal(w, r, h.log, err)
		return false
	}
	return true
}

// syncHead 把服务端状态写成契约的 SyncHead。GET /v1/sync/head、
// GET /v1/sync/snapshot 与 PUT /v1/sync/snapshot 共用这一个形状（ADR-0043）。
func (h *Handler) syncHead(state State) api.SyncHead {
	out := api.SyncHead{
		Head:          state.Head,
		SchemaVersion: h.svc.SchemaVersion(),
		EarliestSeq:   state.EarliestSeq,
	}
	if snap := state.Snapshot; snap != nil {
		out.Snapshot = &api.SyncSnapshot{
			Seq:       snap.Seq,
			Sha256:    snap.SHA256,
			Digest:    snap.Digest,
			CreatedAt: snap.CreatedAt,
		}
	}
	return out
}

func (h *Handler) Head(w http.ResponseWriter, r *http.Request, params api.GetV1SyncHeadParams) {
	p := auth.MustPrincipal(r.Context())
	if id, caps, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		h.recordDevice(r.Context(), p.UserID, id, caps)
	}
	state, err := h.svc.State(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, h.syncHead(state))
}

// Snapshot 返回当前快照指针，形状与 head 相同。
func (h *Handler) Snapshot(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	state, err := h.svc.State(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, h.syncHead(state))
}

func (h *Handler) Pull(w http.ResponseWriter, r *http.Request, params api.GetV1SyncCommitsParams) {
	p := auth.MustPrincipal(r.Context())
	if id, caps, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		h.recordDevice(r.Context(), p.UserID, id, caps)
	}
	result, err := h.svc.Pull(r.Context(), p.UserID, params.After, params.Limit)
	var compacted *CompactedError
	if errors.As(err, &compacted) {
		after := int64(0)
		if params.After != nil {
			after = *params.After
		}
		// extra 是客户端重新克隆需要的全部信息：位置在哪儿丢了、保留下界是多少、
		// 快照指向哪儿。字段名平铺，客户端不用再解一层（ADR-0043）。
		extra := map[string]any{
			"resource":     "sync",
			"after":        after,
			"earliest_seq": compacted.State.EarliestSeq,
			"head":         compacted.State.Head,
		}
		if snap := compacted.State.Snapshot; snap != nil {
			extra["snapshot_seq"] = snap.Seq
			extra["snapshot_sha256"] = snap.SHA256
			extra["snapshot_digest"] = snap.Digest
		}
		httpx.WriteProblemExtra(w, r, http.StatusGone, httpx.CodeHistoryCompacted,
			"pull position is behind the retained lower bound; re-clone from the snapshot", extra)
		return
	}
	if err != nil {
		if errors.Is(err, ErrPullTooLarge) {
			httpx.WriteProblemExtra(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, err.Error(), map[string]any{"resource": "sync"})
			return
		}
		if errors.Is(err, ErrInvalid) {
			httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "after must be non-negative and limit between 1 and 1000")
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	page := api.CommitPage{
		Commits:     result.Commits,
		Head:        result.Head,
		HasMore:     result.HasMore,
		EarliestSeq: result.EarliestSeq,
	}
	if snap := result.Snapshot; snap != nil {
		page.Snapshot = &api.SyncSnapshot{
			Seq:       snap.Seq,
			Sha256:    snap.SHA256,
			Digest:    snap.Digest,
			CreatedAt: snap.CreatedAt,
		}
	}
	httpx.WriteJSON(w, http.StatusOK, page)
}

func (h *Handler) Push(w http.ResponseWriter, r *http.Request, params api.PostV1SyncCommitsParams) {
	p := auth.MustPrincipal(r.Context())
	if !h.allowWrite(w, r, p.UserID) {
		return
	}
	var in api.PostV1SyncCommitsJSONBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	deviceID, capabilities, hasDevice := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities)
	head, err := h.svc.Push(r.Context(), p.UserID, in.BaseSeq, in.Commits)
	if errors.Is(err, ErrStorageFull) {
		httpx.WriteProblemExtra(w, r, http.StatusRequestEntityTooLarge, httpx.CodeStorageFull, err.Error(), map[string]any{"resource": "sync"})
		return
	}
	if errors.Is(err, ErrPushTooLarge) {
		httpx.WriteProblemExtra(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, err.Error(), map[string]any{"resource": "sync"})
		return
	}
	if errors.Is(err, ErrHeadMoved) {
		httpx.WriteProblemExtra(w, r, http.StatusConflict, httpx.CodeConflict,
			"pull and apply remote commits first", map[string]any{"head": head})
		return
	}
	if errors.Is(err, ErrInvalid) {
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"commit failed validation", map[string]any{"schema_version": h.svc.SchemaVersion()})
		return
	}
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	// 名册在推送成功之后更新：带设备标识的请求按头里的能力整组替换，没有头时
	// 按提交里出现的设备标识补行，能力与别名留空（ADR-0048）。
	if hasDevice {
		h.recordDevice(r.Context(), p.UserID, deviceID, capabilities)
	} else {
		h.recordCommitDevices(r.Context(), p.UserID, in.Commits)
	}
	httpx.WriteJSON(w, http.StatusOK, api.PushResult{Head: head})
}

// RegisterSnapshot 登记当前序列位置上的一份快照。位置比已保存的旧时返回 409，
// extra.snapshot_seq 给出当前位置；位置超出 head、两个哈希不是 64 位小写十六
// 进制、附件不属于这个账号或大小不合理时返回 400；没有装配附件查询时返回 501
// （ADR-0043）。
func (h *Handler) RegisterSnapshot(w http.ResponseWriter, r *http.Request, params api.PutV1SyncSnapshotParams) {
	p := auth.MustPrincipal(r.Context())
	if !h.allowWrite(w, r, p.UserID) {
		return
	}
	if id, caps, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		h.recordDevice(r.Context(), p.UserID, id, caps)
	}
	var in api.SnapshotRegistration
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	state, err := h.svc.RegisterSnapshot(r.Context(), p.UserID, in)
	switch {
	case errors.Is(err, ErrSnapshotStale):
		extra := map[string]any{"resource": "sync"}
		if snap := state.Snapshot; snap != nil {
			extra["snapshot_seq"] = snap.Seq
			extra["snapshot_sha256"] = snap.SHA256
		}
		httpx.WriteProblemExtra(w, r, http.StatusConflict, httpx.CodeConflict,
			"a snapshot of a newer position is already registered", extra)
	case errors.Is(err, ErrInvalid):
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"snapshot failed validation: seq must be within the current head, hashes must be 64 lowercase hex characters, and the attachment must be stored for this account within the size limit",
			map[string]any{"resource": "sync"})
	case errors.Is(err, ErrSnapshotUnsupported):
		httpx.WriteProblem(w, r, http.StatusNotImplemented, httpx.CodeNotImplemented, "snapshot registration is not wired")
	case errors.Is(err, ErrStorageFull):
		httpx.WriteProblemExtra(w, r, http.StatusRequestEntityTooLarge, httpx.CodeStorageFull, err.Error(), map[string]any{"resource": "sync"})
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, h.syncHead(state))
	}
}

// Reset 清空当前账号的提交序列并把 head 重置为 0。空序列也回 204，客户端只按
// 状态码判断，不需要先看 head 再决定调不调用。
func (h *Handler) Reset(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if !h.allowWrite(w, r, p.UserID) {
		return
	}
	if err := h.svc.Reset(r.Context(), p.UserID); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Devices 返回账号的设备名册，按最近出现时间倒序，最多 50 条（ADR-0048）。
func (h *Handler) Devices(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	devices, err := h.svc.Devices(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	out := api.SyncDeviceList{Devices: make([]api.SyncDevice, 0, len(devices))}
	for _, device := range devices {
		out.Devices = append(out.Devices, apiDevice(device))
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// RenameDevice 修改一台已知设备的别名。未知设备返回 404；设备标识或别名不合
// 形状时返回 400；清除云端数据期间的改名与其它写请求一样返回 409（ADR-0048）。
func (h *Handler) RenameDevice(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if !h.allowWrite(w, r, p.UserID) {
		return
	}
	var in api.SyncDeviceRename
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	device, err := h.svc.RenameDevice(r.Context(), p.UserID, in.DeviceId, in.Alias)
	switch {
	case errors.Is(err, ErrDeviceNotFound):
		httpx.WriteProblem(w, r, http.StatusNotFound, httpx.CodeNotFound, "device is not in the roster")
	case errors.Is(err, ErrInvalid):
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"device_id must be 1 to 64 bytes and alias at most 64 characters after trimming")
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, apiDevice(device))
	}
}

// deviceFromRequest 取这次请求的设备标识与能力声明。没有设备标识或标识超过 64
// 字节时按没有带处理，名册因此不会被一个不合形状的值写乱。
func deviceFromRequest(deviceID, capabilities *string) (string, []string, bool) {
	if deviceID == nil {
		return "", nil, false
	}
	id := strings.TrimSpace(*deviceID)
	if id == "" || len(id) > maxDeviceIDBytes {
		return "", nil, false
	}
	names := []string{}
	if capabilities != nil {
		names = SplitCapabilities(*capabilities)
	}
	return id, names, true
}

// recordDevice 更新设备名册：最近出现时间写服务端当前时间，能力整组替换，别名
// 不动。写入失败只记日志，不影响这一轮同步的结果（ADR-0048）。
func (h *Handler) recordDevice(ctx context.Context, userID, deviceID string, capabilities []string) {
	if err := h.svc.TouchDevice(ctx, userID, deviceID, capabilities); err != nil {
		h.log.Warn("cannot record a sync device",
			slog.String("user_id", userID),
			slog.String("device_id", deviceID),
			slog.String("error", err.Error()),
		)
	}
}

// recordCommitDevices 在没有设备标识的推送里按提交出现的设备标识补行，能力与
// 别名留空，旧版本客户端因此也会出现在名册里（ADR-0048）。
func (h *Handler) recordCommitDevices(ctx context.Context, userID string, commits []api.Commit) {
	seen := make(map[string]bool, len(commits))
	for _, commit := range commits {
		id := strings.TrimSpace(commit.DeviceId)
		if id == "" || len(id) > maxDeviceIDBytes || seen[id] {
			continue
		}
		seen[id] = true
		if err := h.svc.EnsureDevice(ctx, userID, id); err != nil {
			h.log.Warn("cannot record a sync device from a commit",
				slog.String("user_id", userID),
				slog.String("device_id", id),
				slog.String("error", err.Error()),
			)
		}
	}
}

// apiDevice 把存储层的设备转成契约类型；能力为空时写空数组而不是 null。
func apiDevice(device Device) api.SyncDevice {
	capabilities := device.Capabilities
	if capabilities == nil {
		capabilities = []string{}
	}
	return api.SyncDevice{
		DeviceId:     device.DeviceID,
		Alias:        device.Alias,
		Capabilities: capabilities,
		LastSeen:     device.LastSeen,
	}
}
