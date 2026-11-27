import '../ai/ai_chat_service.dart';
import '../ai/llm_config.dart';
import '../ai/llm_config_store.dart';
import '../data/db/write_transactions.dart';
import '../data/backup/data_version_service.dart';
import '../data/repository/settings_repository.dart';
import '../domain/rules/revision_actions.dart';
import '../data/diagnostics/crash_log.dart';
import '../data/revisions/revision_engine.dart';
import '../domain/models/result.dart';
import '../domain/models/write_result.dart';
import '../domain/rules/day_key.dart';
import '../domain/rules/revision_retention.dart';
import '../domain/rules/time_policy.dart';
import 'crash_reporting.dart';
import 'screen_tables.dart';
import 'service_runtime.dart';
import 'time_policy_controller.dart';
import '../../domain/rules/uuid_v7.dart';

/// 设置页从库里读到的设置项：每日截止小时与拍照方式。
///
/// 截止小时与拍照方式都写在 app_meta 里；恢复、导入与清空之后
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
    required this.diagnostics,
    this.crashReportingDefault = true,
    this.authorizeConfig,
  });

  final SettingsRepository settings;
  final WriteTransactions transactions;
  final LlmConfigStore llmStore;
  final AiChatService ai;
  final ServiceRuntime runtime;

  /// 把模型配置补上知新服务的地址与访问令牌，未登录时抛出 [AccountSignedOut]。
  final Future<LlmConfig> Function(LlmConfig config)? authorizeConfig;

  /// 截止小时与时间口径的持有者；保存之后由它重读，界面立刻用新值。
  final TimePolicyController timePolicy;

  /// 整库恢复与清空；写路径只有数据版本服务一个入口。
  final DataVersionService dataVersions;

  /// 崩溃报告的开关；设备级位置，不随账号空间切换。
  final CrashReportingSwitch diagnostics;

  /// 开关文件读不出来时的默认值：发布包默认关闭，调试包默认开启。
  ///
  /// 取值由装配处按构建模式给出，应用层不引 `package:flutter`。
  final bool crashReportingDefault;

  /// 拍照方式的设置键；值为 '1' 表示用系统相机，其余用应用内相机。
  static const String systemCameraKey = 'capture_system_camera';

  Future<Result<LlmConfig?>> config() => llmStore.read();

  /// 保存配置；只存模型名、上下文上限与图片开关，先确认已经登录，地址与令牌
  /// 本身不写进本机。
  Future<void> saveConfig(LlmConfig config) async {
    await (authorizeConfig?.call(config) ?? Future.value(config));
    await llmStore.save(config);
    ai.setConfigSnapshot(config);
  }

  Future<void> clearConfig() async {
    await llmStore.clear();
    ai.setConfigSnapshot(null);
  }

  /// 连接测试：先把地址与令牌补成一次真实请求要用的样子。
  Future<Duration> testConfig(LlmConfig config) async {
    final prepared =
        await (authorizeConfig?.call(config) ?? Future.value(config));
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
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
    await timePolicy.refresh();
    return result;
  }

  /// 拍照是否走系统相机；默认用应用内相机，快门之后直接进框选。
  Future<bool> useSystemCamera() async =>
      await settings.metadata(systemCameraKey) == '1';

  /// 跟随写入更新的设置项读取；页面订阅之后不再在保存之后自己重读。
  ///
  /// 截止小时保存成一条提交，提交收尾通知 app_meta，页面因此立刻用新值；
  /// 拍照方式写在 app_meta 里，整库恢复与导入时随全部表一起补发（ADR-0014）。
  Stream<SettingsView> watchSettings() => runtime.watch(
    tables: ScreenTables.settings,
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

  /// 崩溃报告的开关：本机诊断文件里的那一项。
  ///
  /// 与启动时读的是同一个文件；读失败按 [crashReportingDefault] 处理，并同步
  /// [CrashLog.reportEnabled]，让本次运行的上报开关与页面显示一致。
  Future<bool> crashReporting() async {
    final enabled = await diagnostics.read(fallback: crashReportingDefault);
    CrashLog.reportEnabled = enabled;
    return enabled;
  }

  /// 保存崩溃报告开关：先改 [CrashLog.reportEnabled]，写存储失败时恢复原值。
  ///
  /// 页面先把开关拨到新值并调用这里；失败时把异常交回页面，由它把开关拨回去
  /// 并提示，顺序与页面原来自己写时一致。
  Future<void> setCrashReporting(bool value) async {
    final previous = CrashLog.reportEnabled;
    CrashLog.reportEnabled = value;
    try {
      await diagnostics.write(value);
    } catch (_) {
      CrashLog.reportEnabled = previous;
      rethrow;
    }
  }

  String exportFileName() {
    final current = runtime.policy;
    final day = current.attributionDay(current.now).replaceAll('-', '');
    return 'zhixin-$day.zip';
  }

  Future<void> resetAllData() => dataVersions.resetAllData();
}
