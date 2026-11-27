package backup

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/periodic"
)

// ReconcileGrace 是遗留对象要超过多久才会被对账删除。上传在对象与元数据之间
// 有一段窗口：备份先写对象、后写元数据行，附件先写索引行、后写对象。宽限期把
// 这段窗口排除在外，避免对账删掉一次还没写完的上传。一小时与 ADR-0037 决定的
// 一致。
const ReconcileGrace = time.Hour

const (
	// backupObjectPrefix 是全部备份对象共用的键前缀，已知集合是 backup 表的
	// (账号, id)。
	backupObjectPrefix = "backups/"
	// attachmentObjectPrefix 是全部附件对象共用的键前缀，已知集合是 attachment
	// 表的 (账号, sha256)。
	attachmentObjectPrefix = "attachments/"
)

// AttachmentKeys 列出附件索引里仍然有效的对象键，由附件存储实现。对账用它把
// attachments/ 下的对象分成仍登记与遗留字节；没有注入时 Reconcile 返回错误，
// 不会只对账备份而把附件永久留在配额里。
type AttachmentKeys interface {
	ListAllKeys(ctx context.Context) ([]string, error)
}

// SetObjects 注入存放备份与附件字节的对象存储，后台对账需要列出并删除
// backups/ 与 attachments/ 下的对象；装配处传入与备份读写同一份存储。没有注入
// 时 Reconcile 返回错误，不会悄悄什么都不做。
func (s *Service) SetObjects(objects objectstore.Store) { s.objects = objects }

// SetAttachmentKeys 注入附件索引那一边的已知键，通常就是附件存储本身；装配处
// 必须调用，否则对账拿不到附件表的行，无法区分仍登记的附件与遗留字节。
func (s *Service) SetAttachmentKeys(keys AttachmentKeys) { s.attachmentKeys = keys }

// SetReconcileInterval 设置后台对账的周期，与配置项
// ZHIXIN_BACKUP_RECONCILE_INTERVAL 对应；设成 0 时只在启动时跑一次。
// 装配处读完配置调用一次。
func (s *Service) SetReconcileInterval(d time.Duration) { s.reconcileInterval = d }

// Reconcile 清理 backups/ 与 attachments/ 下没有元数据的遗留对象，返回删除的
// 对象数。
//
// 备份的 Put 先写对象再写元数据行，Delete 与 TrimBackups 先删行再删对象；附件
// 的 Reserve 先写索引行、Save 再写对象，DeleteUser 先删行再按前缀清字节。任何
// 一步中断都会留下库里没有对应行的对象；上传中断还会在本地目录实现里留下
// .part-* 临时文件。对账只删这种对象，并且要求它比 ReconcileGrace 更旧：宽限期
// 内的对象可能是一次正在进行的上传，不能删。
//
// 两个前缀各跑一次差集：备份侧用 backup 表，附件侧用 attachment 表。附件侧要
// 单独跑，是因为清除云端数据与删号都先删索引行、再按账号前缀清字节，中断之后
// 字节会失去索引，没有行可以登记，只能靠对账收敛。
func (s *Service) Reconcile(ctx context.Context) (int, error) {
	if s.objects == nil {
		return 0, errors.New("backup: 对账没有注入对象存储")
	}
	if s.attachmentKeys == nil {
		return 0, errors.New("backup: 对账没有注入附件索引")
	}
	backupKeys, err := s.store.ListAllKeys(ctx)
	if err != nil {
		return 0, err
	}
	attachmentKeys, err := s.attachmentKeys.ListAllKeys(ctx)
	if err != nil {
		return 0, err
	}
	cutoff := s.now().UTC().Add(-ReconcileGrace)
	removed := 0
	for _, scope := range []struct {
		prefix string
		known  []string
	}{
		{prefix: backupObjectPrefix, known: backupKeys},
		{prefix: attachmentObjectPrefix, known: attachmentKeys},
	} {
		count, err := s.removeOrphans(ctx, scope.prefix, scope.known, cutoff)
		removed += count
		if err != nil {
			return removed, err
		}
	}
	return removed, nil
}

// removeOrphans 删掉 prefix 下不在 known 里、且写入时间早于 cutoff 的对象。
// 写入时间缺失时不动：没有时间就证明不了它超过宽限期，宁可留着。
func (s *Service) removeOrphans(ctx context.Context, prefix string, known []string, cutoff time.Time) (int, error) {
	objects, err := s.objects.List(ctx, prefix)
	if err != nil {
		return 0, err
	}
	live := make(map[string]struct{}, len(known))
	for _, key := range known {
		live[key] = struct{}{}
	}
	removed := 0
	for _, obj := range objects {
		if _, ok := live[obj.Key]; ok {
			continue
		}
		if obj.ModTime.IsZero() || !obj.ModTime.Before(cutoff) {
			continue
		}
		if err := s.objects.Remove(ctx, obj.Key); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

// ReconcileLoop 在启动时对账一次，之后按间隔对账，直到 ctx 结束。间隔为 0 时
// 只跑启动那一次：进程重启至少会收敛一次遗留对象，配置成 0 可以关掉周期清理。
// 对账失败只记日志等下一次再试，遗留对象不影响任何请求。
func (s *Service) ReconcileLoop(ctx context.Context, log *slog.Logger) {
	periodic.Run(ctx, s.reconcileInterval, func() { s.reconcileOnce(ctx, log) })
}

// reconcileOnce 跑一次对账并把结果写进日志；失败不返回，由循环按周期重试。
func (s *Service) reconcileOnce(ctx context.Context, log *slog.Logger) {
	removed, err := s.Reconcile(ctx)
	if err != nil {
		log.Error("reconcile orphan objects", slog.String("error", err.Error()))
		return
	}
	if removed > 0 {
		log.Info("removed orphan objects", slog.Int("objects", removed))
	}
}
