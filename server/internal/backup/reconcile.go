package backup

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/BUPT521/zhixin/server/internal/objectstore"
	"github.com/BUPT521/zhixin/server/internal/periodic"
)

// ReconcileGrace 是遗留对象要超过多久才会被对账删除。Put 先写对象、后写元数据
// 行：正在上传的备份此刻在对象存储里还没有对应的行，宽限期把这段窗口排除在外，
// 避免对账删掉一次还没写完的上传。一小时与 ADR-0037 决定的一致。
const ReconcileGrace = time.Hour

// backupObjectPrefix 是全部备份对象共用的键前缀。对账只在这个范围里删对象，
// attachments/ 下的遗留字节由附件自己的账号前缀清理负责。
const backupObjectPrefix = "backups/"

// SetObjects 注入存放备份字节的对象存储，后台对账需要列出并删除 backups/ 下的
// 对象；装配处传入与备份读写同一份存储。没有注入时 Reconcile 返回错误，不会
// 悄悄什么都不做。
func (s *Service) SetObjects(objects objectstore.Store) { s.objects = objects }

// SetReconcileInterval 设置后台对账的周期，与配置项
// ZHIXIN_BACKUP_RECONCILE_INTERVAL 对应；设成 0 时只在启动时跑一次。
// 装配处读完配置调用一次。
func (s *Service) SetReconcileInterval(d time.Duration) { s.reconcileInterval = d }

// Reconcile 清理 backups/ 下没有元数据的遗留对象，返回删除的对象数。
//
// 备份的 Put 先写对象再写元数据行，Delete 与 TrimBackups 先删行再删对象；任何
// 一步中断都会留下库里没有对应行的对象。对账只删这种对象，并且要求它比
// ReconcileGrace 更旧：宽限期内的对象可能是一次正在进行的上传，不能删。
func (s *Service) Reconcile(ctx context.Context) (int, error) {
	if s.objects == nil {
		return 0, errors.New("backup: 对账没有注入对象存储")
	}
	keys, err := s.store.ListAllKeys(ctx)
	if err != nil {
		return 0, err
	}
	known := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		known[key] = struct{}{}
	}
	objects, err := s.objects.List(ctx, backupObjectPrefix)
	if err != nil {
		return 0, err
	}
	cutoff := s.now().UTC().Add(-ReconcileGrace)
	removed := 0
	for _, obj := range objects {
		if _, ok := known[obj.Key]; ok {
			continue
		}
		// 写入时间缺失时不动：没有时间就证明不了它超过宽限期，宁可留着。
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
		log.Error("reconcile backup objects", slog.String("error", err.Error()))
		return
	}
	if removed > 0 {
		log.Info("removed orphan backup objects", slog.Int("objects", removed))
	}
}
