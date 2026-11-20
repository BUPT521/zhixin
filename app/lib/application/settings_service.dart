import 'dart:typed_data';

import '../ai/ai_chat_service.dart';
import '../ai/llm_config.dart';
import '../ai/llm_config_store.dart';
import '../data/db/write_transactions.dart';
import '../data/backup/data_version_service.dart';
import '../data/repository/settings_repository.dart';
import '../data/revisions/revision_actions.dart';
import '../data/revisions/revision_engine.dart';
import '../domain/models/result.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/day_key.dart';
import '../domain/rules/time_policy.dart';
import 'service_runtime.dart';
import 'time_policy_controller.dart';
import 'command_ids.dart';

/// 设置页从库里读到的设置项：每日截止小时与拍照方式。
///
/// 截止小时写在 profile 里，拍照方式写在 app_meta 里；恢复、导入与清空之后
/// 由应用根按全部表补发一次，页面因此不在这些操作之后自己重读。
class SettingsView {
  const SettingsView({required this.cutoffHour, required this.useSystemCamera});

  final int cutoffHour;
  final bool useSystemCamera;
}

/// 设置页的读写：模型、导出恢复、清空与每日截止小时。
class SettingsService {
  SettingsService({
    required this.settings,
    required this.transactions,
    required this.llmStore,
    required this.ai,
    required this.runtime,
    required this.timePolicy,
    required this.dataVersions,
    this.authorizeConfig,
  });

  final SettingsRepository settings;
  final WriteTransactions transactions;
  final LlmConfigStore llmStore;
  final AiChatService ai;
  final ServiceRuntime runtime;

  /// 把“知新服务”的配置补上访问令牌；未登录时抛出 [AccountSignedOut]。
  final Future<LlmConfig> Function(LlmConfig config)? authorizeConfig;

  /// 截止小时与时间口径的持有者；保存之后由它重读，界面立刻用新值。
  final TimePolicyController timePolicy;

  /// 整库恢复与清空；写路径只有数据版本服务一个入口。
  final DataVersionService dataVersions;

  /// 拍照方式的设置键；值为 '1' 表示用系统相机，其余用应用内相机。
  static const String systemCameraKey = 'capture_system_camera';

  Future<Result<LlmConfig?>> config() => llmStore.read();

  /// 保存配置；选择知新服务时先确认已经登录，令牌本身不写进本机配置。
  Future<void> saveConfig(LlmConfig config) async {
    if (config.isServer) {
      await (authorizeConfig?.call(config) ?? Future.value(config));
    }
    await llmStore.save(config);
    ai.setConfigSnapshot(config);
  }

  Future<void> clearConfig() async {
    await llmStore.clear();
    ai.setConfigSnapshot(null);
  }

  /// 连接测试：知新服务先用当前账号的访问令牌替换配置里的 key。
  Future<Duration> testConfig(LlmConfig config) async {
    final prepared = config.isServer
        ? await (authorizeConfig?.call(config) ?? Future.value(config))
        : config;
    return ai.test(prepared);
  }

  Future<int> cutoffHour() async =>
      requireDayCutoffHour(await settings.cutoffHour() ?? defaultDayCutoffHour);

  /// 截止小时保存成一条提交，数据版本页可以撤销；保存成功后由时间口径控制器
  /// 重新读取，设置页与归属日立刻使用新值。
  Future<WriteResult> saveCutoffHour(int hour) async {
    requireDayCutoffHour(hour);
    final result = await transactions.run(
      (txn) async {
        await settings.setCutoffHour(
          hour,
          runtime.policy.now,
          transaction: txn,
        );
        return txn.result();
      },
      label: changeCutoffHourAction,
      requestId: commandId('set-cutoff-hour', [hour]),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
    await timePolicy.refresh();
    return result;
  }

  /// 拍照是否走系统相机；默认用应用内相机，快门之后直接进框选。
  Future<bool> useSystemCamera() async =>
      await settings.metadata(systemCameraKey) == '1';

  /// 设置页读到的表：截止小时与拍照方式。
  static const Set<String> _settingsTables = {'profile', 'app_meta'};

  /// 跟随写入更新的设置项读取；页面订阅之后不再在保存之后自己重读。
  ///
  /// 截止小时保存成一条提交，提交收尾通知 profile，页面因此立刻用新值；
  /// 拍照方式写在 app_meta 里，整库恢复与导入时随全部表一起补发（ADR-0014）。
  Stream<SettingsView> watchSettings() => runtime.watch(
    tables: _settingsTables,
    read: () async => SettingsView(
      cutoffHour: await cutoffHour(),
      useSystemCamera: await useSystemCamera(),
    ),
  );

  Future<WriteResult> setUseSystemCamera(bool value) =>
      transactions.run((txn) async {
        await settings.setMetadata(
          systemCameraKey,
          value ? '1' : '0',
          runtime.policy.now,
          transaction: txn,
        );
        return txn.result();
      }, label: '设置拍照方式');

  /// 数据版本页的“保留天数”：最近这么多天的提交全部保留，更早的按字节预算
  /// 裁剪。自动裁剪与手动裁剪读同一个值，没有设置时为默认 14 天。
  Future<int> revisionRetentionDays() =>
      dataVersions.engine.retentionDays(dataVersions.connection());

  /// 保存保留天数：只写 `app_meta`，形成一条可以撤销的提交。开发阶段直接换
  /// 键名，不读旧键（ADR-0001）。
  Future<WriteResult> saveRevisionRetentionDays(int days) {
    if (!revisionRetentionDayOptions.contains(days)) {
      throw ArgumentError('保留天数只能是 ${revisionRetentionDayOptions.join('、')} 天');
    }
    return transactions.run((txn) async {
      await settings.setMetadata(
        revisionRetentionDaysKey,
        '$days',
        runtime.policy.now,
        transaction: txn,
      );
      return txn.result();
    }, label: changeRetentionDaysAction);
  }

  String exportFileName() {
    final current = runtime.policy;
    final day = current.attributionDay(current.now).replaceAll('-', '');
    return 'zhixin-$day.zip';
  }

  Future<Result<String?>> restoreBytes(Uint8List bytes) =>
      dataVersions.restore(bytes);

  Future<void> resetAllData() => dataVersions.resetAllData();
}
