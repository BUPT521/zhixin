package backup

import (
	"context"
	"io"
	"time"

	"github.com/BUPT521/zhixin/server/internal/devicename"
	"github.com/BUPT521/zhixin/server/internal/objectstore"
)

// Service owns the snapshot rules that are not HTTP-level: how a device name is
// stored, which metadata is written and how many snapshots are retained. The
// accepted schema version and size limit are only read back through
// SchemaVersion and MaxBytes; the handler rejects requests that break them at
// the HTTP entry, because it must do so before spooling the body.
type Service struct {
	store         Store
	maxBytes      int64
	keep          int
	schemaVersion int
	now           func() time.Time
	// objects 是写字节的同一份对象存储，后台对账用它列出 backups/ 与
	// attachments/ 下的对象；由 NewService 的构造参数给出。
	objects objectstore.Store
	// attachmentKeys 列出仍然登记在附件索引里的对象键，对账据此把 attachments/
	// 下的对象分成仍登记与遗留字节；由 NewService 的构造参数给出，保证对账不会
	// 只处理备份而漏掉附件。
	attachmentKeys AttachmentKeys
	// reconcileInterval 是后台对账的周期，由配置项
	// ZHIXIN_BACKUP_RECONCILE_INTERVAL 设置；0 表示只在启动时跑一次。
	reconcileInterval time.Duration
}

// NewService 组装备份服务。objects 与 attachmentKeys 是后台对账的两份来源，
// 前者列出对象存储里的键、后者列出附件索引里仍登记的键；装配处必须传入，
// 对账因此没有“没有注入”的降级路径（ADR-0037）。
func NewService(store Store, objects objectstore.Store, attachmentKeys AttachmentKeys, maxBytes int64, keep, schemaVersion int) *Service {
	return &Service{
		store:          store,
		objects:        objects,
		attachmentKeys: attachmentKeys,
		maxBytes:       maxBytes,
		keep:           keep,
		schemaVersion:  schemaVersion,
		now:            time.Now,
	}
}

func (s *Service) SchemaVersion() int { return s.schemaVersion }

func (s *Service) MaxBytes() int64 { return s.maxBytes }

// Upload stores one snapshot. The caller has already checked the body hash, the
// schema version against SchemaVersion and the size against MaxBytes; this layer
// cleans the device name, builds the metadata and stores the bytes.
func (s *Service) Upload(
	ctx context.Context,
	userID, sha string,
	schema int,
	device string,
	size int64,
	data io.Reader,
) (Meta, error) {
	device = devicename.Clean(device)
	meta := Meta{
		ID:            newID(),
		SHA256:        sha,
		Size:          size,
		SchemaVersion: schema,
		DeviceName:    device,
		CreatedAt:     s.now().UTC(),
	}
	if err := s.store.Put(ctx, userID, meta, data, s.keep); err != nil {
		return Meta{}, err
	}
	return meta, nil
}

func (s *Service) List(ctx context.Context, userID string) ([]Meta, error) {
	return s.store.List(ctx, userID)
}

// Open 返回一份备份的元数据与字节。id 形状不对时按“没有这份备份”处理，不把
// 数据库或对象存储的查询交给一个客户端随手拼出来的字符串。
func (s *Service) Open(ctx context.Context, userID, id string) (Meta, io.ReadCloser, error) {
	if !validID(id) {
		return Meta{}, nil, ErrNotFound
	}
	return s.store.Open(ctx, userID, id)
}

// Delete 删除一份备份。归属校验分两层：这里先拒绝形状不合法的 id，存储层再按
// (user_id, id) 一起查条件，删到一行才动对象键。
func (s *Service) Delete(ctx context.Context, userID, id string) error {
	if !validID(id) {
		return ErrNotFound
	}
	return s.store.Delete(ctx, userID, id)
}

// validID 报告 id 是不是服务端生成的备份 id：32 位小写十六进制（16 字节随机数的
// hex 编码）。
//
// 这一层校验不能省：id 会直接拼进对象存储的键 backups/<账号>/<id>.zip，而
// filepath.IsLocal 只保证键不逃出存储根目录，不保证不跨账号——像
// "backups/u1/../u2/<id>.zip" 这样的键在清理之后仍是目录内的相对路径，会被
// 目录实现放行。形状校验加上数据库的 (user_id, id) 条件，才是账号隔离。
func validID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// DeleteAll 清空账号在云端的全部备份。保留账号只清云端数据是设置页的独立动作，
// 规则留在这里而不是处理器里：账下没有备份时同样成功，存储失败原样上抛。
func (s *Service) DeleteAll(ctx context.Context, userID string) error {
	return s.store.DeleteAll(ctx, userID)
}
