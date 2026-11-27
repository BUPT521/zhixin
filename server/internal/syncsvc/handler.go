package syncsvc

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/auth"
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
}

// NewHandler wires the handler.
func NewHandler(svc *Service, log *slog.Logger, maxBytes int64) *Handler {
	return &Handler{svc: svc, log: log, maxBytes: min(maxBytes, MaxPushBytes)}
}

// syncHead 把服务端状态写成契约的 SyncHead。GET /v1/sync/head、
// GET /v1/sync/snapshot 与 PUT /v1/sync/snapshot 共用这一个形状（ADR-0043）。
func (h *Handler) syncHead(state State) api.SyncHead {
	out := api.SyncHead{
		Head:          state.Head,
		SchemaVersion: h.svc.SchemaVersion(),
		EarliestSeq:   state.EarliestSeq,
		// 压缩开关由服务端告诉客户端：关闭时客户端不上传整库快照，登记也不会
		// 删提交，快照上传只是白占附件配额（ADR-0047）。
		Compact: h.svc.Compact(),
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
	state, err := h.svc.State(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	// 设备位置只由拉取与推送推进：head 查询只知道服务端的最新位置，不知道这台
	// 设备读到了哪，所以它只更新最近出现时间与快照能力（ADR-0054）。
	if id, capable, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		h.recordDeviceAt(r.Context(), p.UserID, id, capable)
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
	position := int64(0)
	if params.After != nil {
		position = *params.After
	}
	if id, capable, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		// 拉取请求里的 after 就是这台设备已经应用到的位置：整页应用并保存之后才
		// 发下一页，所以它不会高估（ADR-0054）。
		h.recordDevice(r.Context(), p.UserID, id, capable, position)
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
		if h.writeSyncProblem(w, r, err, "after must be non-negative and limit between 1 and 1000", nil) {
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
	var in api.PostV1SyncCommitsJSONBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	deviceID, capable, hasDevice := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities)
	roster := DeviceRoster{}
	if hasDevice {
		roster.Touch = &DeviceClaim{DeviceID: deviceID, SnapshotCapable: capable}
	} else {
		roster.Ensure = commitDevices(in.Commits)
	}
	result, err := h.svc.Push(r.Context(), p.UserID, in.BaseSeq, in.Commits, roster)
	if err != nil {
		extra := map[string]any{}
		if errors.Is(err, ErrHeadMoved) {
			extra["head"] = result.Head
		}
		if errors.Is(err, ErrInvalid) {
			extra["schema_version"] = h.svc.SchemaVersion()
		}
		if h.writeSyncProblem(w, r, err, "commit failed validation", extra) {
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	// 名册已在 Append 的事务里更新：带设备标识时推进这一台的位置，没有标识时
	// 按提交里出现的设备标识补行。这里不再写第二遍，也不再用序号比较判断有没有
	// 新提交（ADR-0048、ADR-0054）。
	seqs := result.Seqs
	if seqs == nil {
		seqs = []int64{}
	}
	httpx.WriteJSON(w, http.StatusOK, api.PushResult{Head: result.Head, Seqs: seqs})
}

// RegisterSnapshot 登记当前序列位置上的一份快照。位置比已保存的旧时返回 409，
// extra.snapshot_seq 给出当前位置；位置超出 head、两个哈希不是 64 位小写十六
// 进制或大小不合理时返回 400；附件还没有上传到这个账号时返回 404；没有装配附件
// 查询时返回 501（ADR-0043）。
func (h *Handler) RegisterSnapshot(w http.ResponseWriter, r *http.Request, params api.PutV1SyncSnapshotParams) {
	p := auth.MustPrincipal(r.Context())
	if id, capable, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		h.recordDeviceAt(r.Context(), p.UserID, id, capable)
	}
	var in api.SnapshotRegistration
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	state, err := h.svc.RegisterSnapshot(r.Context(), p.UserID, in)
	if err != nil {
		extra := map[string]any{}
		if errors.Is(err, ErrSnapshotStale) {
			if snap := state.Snapshot; snap != nil {
				extra["snapshot_seq"] = snap.Seq
				extra["snapshot_sha256"] = snap.SHA256
			}
		}
		detail := "snapshot failed validation: seq must be within the current head, hashes must be 64 lowercase hex characters, and the attachment must be within the size limit"
		if h.writeSyncProblem(w, r, err, detail, extra) {
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, h.syncHead(state))
}

// Reset 清空当前账号的提交序列、快照指针、设备名册与命名版本并把 head 重置为 0。
// 空序列也回 204，客户端只按状态码判断，不需要先看 head 再决定调不调用。
func (h *Handler) Reset(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	if err := h.svc.Reset(r.Context(), p.UserID); err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Devices 返回账号的设备名册，按最近出现时间倒序，最多 50 条。带设备标识时先
// 更新这台设备的名册记录，刚登录、还没同步过的设备因此也能先出现在名册里
// （ADR-0048）。
func (h *Handler) Devices(w http.ResponseWriter, r *http.Request, params api.GetV1SyncDevicesParams) {
	p := auth.MustPrincipal(r.Context())
	if id, capable, ok := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities); ok {
		h.recordDeviceAt(r.Context(), p.UserID, id, capable)
	}
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
	var in api.SyncDeviceRename
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	device, err := h.svc.RenameDevice(r.Context(), p.UserID, in.DeviceId, in.Alias)
	if err != nil {
		if h.writeSyncProblem(w, r, err,
			"device_id must be 1 to 64 bytes and alias at most 64 characters after trimming", nil) {
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, apiDevice(device))
}

// Refs 返回本账号全部命名版本，包括删除之后留下的墓碑（ADR-0054）。
func (h *Handler) Refs(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	refs, err := h.svc.Refs(r.Context(), p.UserID)
	if err != nil {
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	out := api.SyncRefList{Refs: make([]api.SyncRef, 0, len(refs))}
	for _, ref := range refs {
		out.Refs = append(out.Refs, apiRef(ref))
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// PutRef 写入或删除一个命名版本，响应是写入之后的那一行。名字、引用与备注不合
// 形状，或未删除的名字超过每账号上限时返回 400 invalid_request；名字是墓碑且这次
// 写入早于删除时间时不复活，返回的仍是墓碑；清除云端数据期间与其它写请求一样返回
// 409（ADR-0054）。
func (h *Handler) PutRef(w http.ResponseWriter, r *http.Request) {
	p := auth.MustPrincipal(r.Context())
	var in api.SyncRefWrite
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	ref, err := h.svc.PutRef(r.Context(), p.UserID, in)
	if err != nil {
		extra := map[string]any{}
		if errors.Is(err, ErrRefLimit) {
			extra["limit"] = MaxRefsPerAccount
		}
		if h.writeSyncProblem(w, r, err,
			"a ref needs a name of 1 to 30 characters after NFC normalization, a commit_uid of at most 64 bytes when writing, and no more than 200 characters of note", extra) {
			return
		}
		httpx.WriteInternal(w, r, h.log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, apiRef(ref))
}

// apiRef 把存储层的命名版本转成契约类型；删除时间为零值时省略这个键，客户端据此
// 区分名字仍然有效与墓碑。
func apiRef(ref Ref) api.SyncRef {
	out := api.SyncRef{
		Name:      ref.Name,
		CommitUid: ref.CommitUID,
		Note:      ref.Note,
		UpdatedAt: ref.UpdatedAt,
	}
	if !ref.DeletedAt.IsZero() {
		deletedAt := ref.DeletedAt
		out.DeletedAt = &deletedAt
	}
	return out
}

// deviceFromRequest 取这次请求的设备标识与快照能力。没有设备标识或标识超过 64
// 字节时按没有带处理，名册因此不会被一个不合形状的值写乱；能力头里含 snapshot
// 才算支持快照，其余取值忽略（ADR-0048、ADR-0054）。
func deviceFromRequest(deviceID, capabilities *string) (string, bool, bool) {
	if deviceID == nil {
		return "", false, false
	}
	id := strings.TrimSpace(*deviceID)
	if id == "" || len(id) > maxDeviceIDBytes {
		return "", false, false
	}
	capable := false
	if capabilities != nil {
		for _, name := range SplitCapabilities(*capabilities) {
			if name == capabilitySnapshot {
				capable = true
			}
		}
	}
	return id, capable, true
}

// recordDeviceAt 只更新名册里的快照能力与最近出现时间，不动设备位置：head 查询、
// 快照登记、名册查询与改名这几条路径本身不说明这台设备读到了哪（ADR-0054）。
// 位置传负值，服务端按 0 处理，已有设备的位置因此保持不变；新设备以 0 进名册。
// 能力与位置都没有变化时写入被跳过，进行中的同步因此不必每请求写一行（ADR-0048）。
func (h *Handler) recordDeviceAt(ctx context.Context, userID, deviceID string, snapshotCapable bool) {
	h.recordDevice(ctx, userID, deviceID, snapshotCapable, -1)
}

// RosterWriteSuppressed 报告这次请求是否跳过设备名册更新。清除云端数据期间
// cloudOperations 为会写名册的读接口设置这个标记：读取照常返回，名册写入若落在
// 提交序列清空之后，会把已经删掉的行重新插回去。
func RosterWriteSuppressed(ctx context.Context) bool {
	suppressed, _ := ctx.Value(rosterWriteKey{}).(bool)
	return suppressed
}

// SuppressRosterWrite 让一次请求只读：处理器跳过设备名册更新，其余行为不变。
func SuppressRosterWrite(ctx context.Context) context.Context {
	return context.WithValue(ctx, rosterWriteKey{}, true)
}

// rosterWriteKey 是 SuppressRosterWrite 使用的上下文键。
type rosterWriteKey struct{}

// recordDevice 更新设备名册：快照能力整组替换，位置按 position 取较大值且不超过
// 当前 head，别名不动；最近出现时间只在能力或位置变化时前进。写入失败只记日志，
// 不影响这一轮同步的结果（ADR-0048、ADR-0054）。清除云端数据期间的读取请求由
// RosterWriteSuppressed 标记，直接跳过写入。
func (h *Handler) recordDevice(ctx context.Context, userID, deviceID string, snapshotCapable bool, position int64) {
	if RosterWriteSuppressed(ctx) {
		return
	}
	if err := h.svc.TouchDevice(ctx, userID, deviceID, snapshotCapable, position); err != nil {
		h.log.Warn("cannot record a sync device",
			slog.String("user_id", userID),
			slog.String("device_id", deviceID),
			slog.String("error", err.Error()),
		)
	}
}

// writeSyncProblem 把同步接口的服务错误写成 problem+json，返回是否已经写过。
// 状态码与 problem code 集中在这一处，五个处理器不再各维护一张 errors.Is 表；
// invalidDetail 是 ErrInvalid 在当次调用里的具体说明，其余错误用固定说明。
func (h *Handler) writeSyncProblem(w http.ResponseWriter, r *http.Request, err error, invalidDetail string, extra map[string]any) bool {
	var (
		status int
		code   httpx.Code
		detail string
	)
	switch {
	case errors.Is(err, ErrInvalid):
		status, code, detail = http.StatusBadRequest, httpx.CodeInvalidRequest, invalidDetail
	case errors.Is(err, ErrSnapshotAttachmentMissing):
		status, code, detail = http.StatusNotFound, httpx.CodeNotFound,
			"snapshot attachment is not stored for this account; upload it first"
	case errors.Is(err, ErrSnapshotStale):
		status, code, detail = http.StatusConflict, httpx.CodeConflict,
			"a snapshot of a newer position is already registered"
	case errors.Is(err, ErrHeadMoved):
		status, code, detail = http.StatusConflict, httpx.CodeConflict,
			"pull and apply remote commits first"
	case errors.Is(err, ErrSnapshotUnsupported):
		status, code, detail = http.StatusNotImplemented, httpx.CodeNotImplemented,
			"snapshot registration is not wired"
	case errors.Is(err, ErrStorageFull):
		status, code, detail = http.StatusRequestEntityTooLarge, httpx.CodeStorageFull, err.Error()
	case errors.Is(err, ErrPushTooLarge), errors.Is(err, ErrPullTooLarge):
		status, code, detail = http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, err.Error()
	case errors.Is(err, ErrDeviceNotFound):
		status, code, detail = http.StatusNotFound, httpx.CodeNotFound, "device is not in the roster"
	case errors.Is(err, ErrRefLimit):
		status, code, detail = http.StatusBadRequest, httpx.CodeInvalidRequest,
			"an account holds at most 200 named refs that are not deleted"
	default:
		return false
	}
	if extra == nil {
		extra = map[string]any{}
	}
	if _, ok := extra["resource"]; !ok {
		extra["resource"] = "sync"
	}
	httpx.WriteProblemExtra(w, r, status, code, detail, extra)
	return true
}

// apiDevice 把存储层的设备转成契约类型。
func apiDevice(device Device) api.SyncDevice {
	return api.SyncDevice{
		DeviceId:        device.DeviceID,
		Alias:           device.Alias,
		SnapshotCapable: device.SnapshotCapable,
		SyncedSeq:       device.SyncedSeq,
		LastSeen:        device.LastSeen,
	}
}
