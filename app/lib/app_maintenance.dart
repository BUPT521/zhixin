import 'dart:async';

import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'app_composition.dart';
import 'data/attachment_store.dart';

/// 首帧之后的后台维护：附件整理、语义索引补建、同步调度与匿名上报。
///
/// 这些事与用户此刻的操作无关，失败只写诊断记录，不打断界面：下一次启动或
/// 下一次提交还会重做，不值得用一个提示打断使用。
class AppMaintenance {
  AppMaintenance(this._composition);

  final AppComposition _composition;

  /// 写入触发的索引刷新静默期：连续提交时等最后一次写入之后只扫一次库。
  static const Duration searchIndexQuietPeriod = Duration(seconds: 3);

  Timer? _searchIndexRefreshTimer;
  bool _disposed = false;

  /// 首帧交出之后在后台整理附件：先删掉数据库不再引用的图片，必要时补建缓存。
  ///
  /// 两步互不阻塞，各自失败只写诊断记录：它们与用户此刻的操作无关，下一次
  /// 启动还会重做。缓存补建只在还原、导入之后或缓存目录被系统清空时做，平时
  /// 启动只做删除这一趟，避免每次全表扫描消息。
  void scheduleAttachmentMaintenance() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(maintainAttachments());
    });
  }

  Future<void> maintainAttachments() async {
    if (_composition.closing) return;
    try {
      await AttachmentStore(filesDir: _composition.paths.filesDir)
          .cleanupUnreferenced(_composition.db);
    } catch (error, stack) {
      _composition.crashLog.record(error, stack, kind: 'cleanup_attachments');
    }
    if (_disposed || _composition.closing) return;
    try {
      await _composition.gate.shared(() async {
        final cache = _composition.attachmentCache;
        if (!await cache.needsRebuild) return;
        await cache.rebuild(_composition.db, _composition.engine.assets);
        await cache.clearPendingRebuild();
      });
    } catch (error, stack) {
      // 补建失败不打断使用：缺图的位置已经按“找不到图片”显示，下次再补。
      _composition.crashLog.record(error, stack, kind: 'rebuild_attachments');
    }
  }

  /// 首帧之后在空闲里尝试一次匿名活跃上报（ADR-0019）：不等待、不阻塞启动，
  /// 失败只写诊断记录；登录用户由服务端按请求日期统计，这一步会直接跳过。
  ///
  /// 首次启动引导里同意用户须知之前不上报：老用户可能已经看过匿名统计说明，
  /// 只看说明这一层拦不住，这里再按联网开关确认一次。
  void scheduleActiveReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !_composition.networkAllowed) return;
      unawaited(
        _composition.activeReport?.reportIfDue() ?? Future<void>.value(),
      );
    });
  }

  /// 一次提交落库之后调用：来源表变了就排在安静期之后补建索引。
  void onCommitted(Set<String> tables) {
    // 登录之后写入随自动同步推到服务端；同步本身应用的远端提交也会走到这里，
    // 这时没有待推送的提交，下一次同步只做一次位置核对。
    final sync = _composition.sync;
    if (sync != null) unawaited(sync.schedule());
    if (!tables.any(AppComposition.searchIndexSourceTables.contains)) return;
    refreshSearchIndex();
  }

  /// 数据代次变化后按当前数据补建检索索引；没有配置时只建全文索引。
  ///
  /// 来源表有提交之后与数据代次变化之后都走这里，等 [searchIndexQuietPeriod]
  /// 再执行，期间再次触发只顺延，避免连续提交时每次都全量扫库；立即需要索引的
  /// 入口仍直接调用刷新。
  void refreshSearchIndex() {
    final index = _composition.currentSearchIndex;
    if (index == null || !index.configured) return;
    cancelIndexTimer();
    _searchIndexRefreshTimer = Timer(searchIndexQuietPeriod, () {
      _searchIndexRefreshTimer = null;
      refreshSearchIndexNow();
    });
  }

  /// 后台补建索引；失败只写诊断记录，不打断界面，回答继续使用字面命中。
  ///
  /// 设置页的手动“更新索引”直接调用服务并捕获异常，看到的是就地说明。
  void refreshSearchIndexNow() {
    unawaited(refreshSearchIndexNowAndWait());
  }

  /// 同 [refreshSearchIndexNow]，但把这一次刷新等完：冲刷记忆使用统计之后
  /// 要等索引写完再结束，不留下一个没人等的写入。
  Future<void> refreshSearchIndexNowAndWait() async {
    final index = _composition.currentSearchIndex;
    if (index == null || !index.configured) return;
    try {
      await index.refresh();
    } catch (error, stack) {
      _composition.crashLog.record(error, stack, kind: 'semantic_index');
    }
  }

  /// 应用进入后台时冲刷记忆使用统计：距上次冲刷不少于一天才写（ADR-0051
  /// 决定第 8 条）。失败只写诊断记录，与用户此刻的操作无关。
  void flushMemoryUsageOnPause() {
    unawaited(
      _composition.memoryUsage.flushIfDue().catchError((
        Object error,
        StackTrace stack,
      ) {
        _composition.crashLog.record(error, stack, kind: 'memory_usage_flush');
        return false;
      }),
    );
  }

  /// 取消排着的索引刷新；换空间、关库与状态释放之前都要先停掉它。
  void cancelIndexTimer() {
    _searchIndexRefreshTimer?.cancel();
    _searchIndexRefreshTimer = null;
  }

  /// 状态释放：不再开始新的后台步骤，排着的刷新一并取消。
  void dispose() {
    _disposed = true;
    cancelIndexTimer();
  }
}
