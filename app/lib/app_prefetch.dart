import 'package:flutter/foundation.dart' show kReleaseMode;

import 'app_composition.dart';
import 'application/prefetch_service.dart';
import 'application/search_index_service.dart' show IndexStats;
import 'data/diagnostics/crash_log.dart';
import 'platform/diagnostics_store.dart';

/// 二级界面首屏的预读策略：一级界面切进来之后，在后台读一次它下面几个二级
/// 界面的首屏（ADR-0029）。
///
/// 只读首屏一份结果，不保持订阅：页面打开之后照常订阅数据层的更新，写入、
/// 撤销与换库之后仍由数据层推送重读（ADR-0014）。启动时不把四个栏目的二级
/// 页面一起读：首屏只承担首页与其余三栏本身，用不到的内容不占启动时间与内存。
class AppPrefetchPolicy {
  AppPrefetchPolicy(this._composition);

  final AppComposition _composition;

  /// 预读入口；页面打开时先看有没有已经读完的结果。
  late final PrefetchService prefetch = PrefetchService(
    clock: _composition.clock,
    tasks: {
      PrefetchArea.now: [_warmMemoryPage],
      PrefetchArea.records: [_warmRecordsSearchOptions, _warmEmbeddingSettings],
      PrefetchArea.plan: [_warmPlanSearchOptions],
      PrefetchArea.mine: [
        _warmMemoryPage,
        _warmDataVersionPage,
        _warmSettingsPage,
        _warmCloudBackups,
        _warmPluginSettings,
      ],
    },
  );

  /// 记忆页一屏：从这一栏进入记忆时直接有内容。
  Future<void> _warmMemoryPage() async {
    await prefetch.warm(
      PrefetchKey.memory,
      () => _composition.services.memory.edit.watchMemories().first,
    );
  }

  /// 数据版本页一屏：读历史、撤销判断、存储占用与恢复点，通常是这几页里最慢的一页。
  Future<void> _warmDataVersionPage() async {
    await prefetch.warm(
      PrefetchKey.dataVersion,
      () => _composition.services.data.versions.watchOverview().first,
    );
  }

  /// 记录查找的范围选项：目标与材料，查找页打开时不再等这两项。
  Future<void> _warmRecordsSearchOptions() async {
    await prefetch.warm(PrefetchKey.recordsSearchOptions, () async {
      final (goals, materials) = await (
        _composition.services.study.plan.activeGoals(),
        _composition.services.library.material.list(),
      ).wait;
      return (goals: goals, materials: materials);
    });
  }

  /// 安排查找的目标选项。
  Future<void> _warmPlanSearchOptions() async {
    await prefetch.warm(
      PrefetchKey.planSearchGoals,
      _composition.services.study.plan.goals,
    );
  }

  /// 设置页本机读取的一组结果：模型配置、账号、可选模型与索引概况。
  ///
  /// 网络读取失败只留空，与设置页自己读到失败时的处理一致，不影响本机配置。
  Future<void> _warmSettingsPage() async {
    await prefetch.warm(PrefetchKey.settings, () async {
      final services = _composition.services;
      final config = await services.settings.edit.config();
      final account = services.account.account;
      final snapshot = await account.snapshot();
      var models = const <String>[];
      if (snapshot.signedIn && await account.developerMode()) {
        try {
          models = [
            for (final model in await account.models())
              if (model.isChat) model.id,
          ];
        } catch (_) {
          // 模型列表只用于提示；读不到时与设置页的处理一样留空。
        }
      }
      final embedding = await services.settings.embedding.summary();
      final reportCrashes = await DiagnosticsStore(
        _composition.devicePaths.filesDir,
      ).read(fallback: !kReleaseMode);
      CrashLog.reportEnabled = reportCrashes;
      final reportUsage = await services.account.activeReport.enabled();
      return (
        config: config,
        account: snapshot,
        models: models,
        embedding: embedding,
        reportCrashes: reportCrashes,
        reportUsage: reportUsage,
      );
    });
  }

  /// 云端备份列表：只有登录之后才有，未登录时这一项不读。
  Future<void> _warmCloudBackups() async {
    final services = _composition.services;
    if (!(await services.account.account.snapshot()).signedIn) return;
    await prefetch.warm(
      PrefetchKey.cloudBackups,
      services.account.backups.list,
    );
  }

  /// 人格与插件页读的 `app_meta`：运行时提前加载一次，两页打开时不再摆骨架。
  Future<void> _warmPluginSettings() async {
    await prefetch.warm(PrefetchKey.pluginSettings, () async {
      await _composition.services.plugins.runtime.load();
      return true;
    });
  }

  /// 语义索引设置页的一组结果：配置、材料、登录状态与索引状态。
  Future<void> _warmEmbeddingSettings() async {
    await prefetch.warm(PrefetchKey.embeddingSettings, () async {
      final services = _composition.services;
      final embedding = services.settings.embedding;
      final config = await embedding.read();
      final materials = await services.library.material.list();
      final signedIn = (await services.account.account.snapshot()).signedIn;
      IndexStats? stats;
      if (embedding.configured) {
        try {
          stats = await services.library.searchIndex.stats();
        } catch (_) {
          // 索引状态读不出来时页面自己读会给出同样的说明，这里只留空。
        }
      }
      return (
        config: config,
        materials: materials,
        signedIn: signedIn,
        stats: stats,
      );
    });
  }
}
