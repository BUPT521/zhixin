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
	var in api.PostV1SyncCommitsJSONBody
	if !httpx.DecodeJSON(w, r, h.maxBytes, &in) {
		return
	}
	deviceID, capable, hasDevice := deviceFromRequest(params.XDeviceId, params.XSyncCapabilities)
	result, err := h.svc.Push(r.Context(), p.UserID, in.BaseSeq, in.Commits)
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
			"pull and apply remote commits first", map[string]any{"head": result.Head})
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
	// 名册在推送成功之后更新：带设备标识的请求按头里的快照能力整组替换、位置按
	// base 推进，没有头时按提交里出现的设备标识补行（ADR-0048、ADR-0054）。
	if hasDevice {
		h.recordDevice(r.Context(), p.UserID, deviceID, capable, in.BaseSeq)
		// 确有新提交写入时才推进到当前 head：整批重放说明设备没有读到别的设备
		// 在这期间推的提交，位置只按 base 取较大值。
		if err := h.svc.AdvanceDevice(r.Context(), p.UserID, deviceID, in.BaseSeq, newCommits(in.Commits, result.Seqs, in.BaseSeq)); err != nil {
			h.log.Warn("cannot advance a sync device position",
				slog.String("user_id", p.UserID),
				slog.String("device_id", deviceID),
				slog.String("error", err.Error()),
			)
		}
	} else {
		h.recordCommitDevices(r.Context(), p.UserID, in.Commits)
	}
	seqs := result.Seqs
	if seqs == nil {
		seqs = []int64{}
	}
	httpx.WriteJSON(w, http.StatusOK, api.PushResult{Head: result.Head, Seqs: seqs})
}

// newCommits 报告这批提交里有没有服务端新写入的：序号大于 base 的提交是新分配的，
// 全部不大于 base 说明整批都是重放（ADR-0054）。
func newCommits(commits []api.Commit, seqs []int64, base int64) bool {
	for i := range commits {
		if i < len(seqs) && seqs[i] > base {
			return true
		}
	}
	return false
}

// RegisterSnapshot 登记当前序列位置上的一份快照。位置比已保存的旧时返回 409，
// extra.snapshot_seq 给出当前位置；位置超出 head、两个哈希不是 64 位小写十六
// 进制、附件不属于这个账号或大小不合理时返回 400；没有装配附件查询时返回 501
// （ADR-0043）。
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
	switch {
	case errors.Is(err, ErrRefLimit):
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"an account holds at most 200 named refs that are not deleted",
			map[string]any{"resource": "sync", "limit": MaxRefsPerAccount})
	case errors.Is(err, ErrInvalid):
		httpx.WriteProblemExtra(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest,
			"a ref needs a name of 1 to 30 characters after NFC normalization, a commit_uid of at most 64 bytes when writing, and no more than 200 characters of note",
			map[string]any{"resource": "sync"})
	case err != nil:
		httpx.WriteInternal(w, r, h.log, err)
	default:
		httpx.WriteJSON(w, http.StatusOK, apiRef(ref))
	}
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

// recordDevice 更新设备名册：快照能力整组替换，位置按 position 取较大值且不超过
// 当前 head，别名不动；最近出现时间只在能力或位置变化时前进。写入失败只记日志，
// 不影响这一轮同步的结果（ADR-0048、ADR-0054）。
func (h *Handler) recordDevice(ctx context.Context, userID, deviceID string, snapshotCapable bool, position int64) {
	if err := h.svc.TouchDevice(ctx, userID, deviceID, snapshotCapable, position); err != nil {
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
