import 'dart:typed_data';

import '../ai/ai_chat_service.dart';
import '../ai/llm_config.dart';
import '../ai/llm_config_store.dart';
import '../data/db/write_transactions.dart';
import '../data/backup/data_version_service.dart';
import '../data/repository/settings_repository.dart';
import '../data/revisions/revision_actions.dart';
import '../domain/models/result.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/day_key.dart';
import '../domain/rules/time_policy.dart';
import 'service_runtime.dart';

/// 设置页的读写：模型、导出恢复、清空与每日截止小时。
class SettingsService {
  SettingsService({
    required this.settings,
    required this.transactions,
    required this.llmStore,
    required this.ai,
    required this.runtime,
    required this.onPolicyChanged,
    required this.dataVersions,
  });

  final SettingsRepository settings;
  final WriteTransactions transactions;
  final LlmConfigStore llmStore;
  final AiChatService ai;
  final ServiceRuntime runtime;

  /// 截止小时保存后重新读取到应用根；界面与时间口径立刻使用新值。
  final Future<void> Function() onPolicyChanged;

  /// 整库恢复与清空；写路径只有数据版本服务一个入口。
  final DataVersionService dataVersions;

  /// 拍照方式的设置键；值为 '1' 表示用系统相机，其余用应用内相机。
  static const String systemCameraKey = 'capture_system_camera';

  Future<LlmConfig?> config() => llmStore.read();

  Future<void> saveConfig(LlmConfig config) async {
    await llmStore.save(config);
    ai.setConfigSnapshot(config);
  }

  Future<void> clearConfig() async {
    await llmStore.clear();
    ai.setConfigSnapshot(null);
  }

  Future<Duration> testConfig(LlmConfig config) => ai.test(config);

  Future<int> cutoffHour() async =>
      requireDayCutoffHour(await settings.cutoffHour() ?? defaultDayCutoffHour);

  /// 截止小时保存成一条提交，数据版本页可以撤销；保存成功后立即刷新应用
  /// 根缓存的时间口径。
  Future<WriteResult> saveCutoffHour(int hour) async {
    requireDayCutoffHour(hour);
    final result = await transactions.run((txn) async {
      await settings.setCutoffHour(hour, runtime.policy.now, transaction: txn);
      return txn.result();
    }, label: changeCutoffHourAction);
    await onPolicyChanged();
    return result;
  }

  /// 拍照是否走系统相机；默认用应用内相机，快门之后直接进框选。
  Future<bool> useSystemCamera() async =>
      await settings.metadata(systemCameraKey) == '1';

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

  String exportFileName() {
    final current = runtime.policy;
    final day = current.attributionDay(current.now).replaceAll('-', '');
    return 'zhixin-$day.zip';
  }

  Future<Result<String?>> restoreBytes(Uint8List bytes) =>
      dataVersions.restore(bytes);

  Future<void> resetAllData() => dataVersions.resetAllData();
}
