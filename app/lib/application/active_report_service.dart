import 'dart:async';
import 'dart:io';

import '../data/cloud/server_client.dart';
import '../data/cloud/telemetry_store.dart';
import '../data/diagnostics/crash_log.dart';

/// 不登录时的匿名活跃上报（ADR-0019）：每天最多一次，只有随机安装标识、应用
/// 版本与平台，不含学习内容。
///
/// 登录之后的活跃由服务端按请求日期统计，这里直接跳过，避免同一台设备算两次。
/// 上报在启动之后的空闲任务里发出，失败静默重试一次，仍失败只写本机诊断记录，
/// 不打断使用、不弹提示。
class ActiveReportService {
  ActiveReportService({
    required this.store,
    required this.signedIn,
    required this.serverBaseUrl,
    required this.crashLog,
    required this.appVersion,
    DateTime Function()? clock,
    ServerClient Function(String baseUrl)? clientFactory,
    this.retryDelay = const Duration(seconds: 3),
  }) : _clock = clock ?? DateTime.now,
       _clientFactory =
           clientFactory ?? ((baseUrl) => ServerClient(baseUrl: baseUrl));

  final TelemetryStore store;

  /// 当前是否有登录账号；有账号时服务端已经按请求日期统计活跃。
  final Future<bool> Function() signedIn;

  /// 当前知新服务地址；匿名上报也发到同一个实例。
  final Future<String> Function() serverBaseUrl;

  final CrashLog crashLog;
  final String appVersion;
  final DateTime Function() _clock;
  final ServerClient Function(String baseUrl) _clientFactory;

  /// 失败之后重试一次之前的等待；测试传零，避免真的等。
  final Duration retryDelay;

  /// 申请一次上报：满足条件时发一次请求，同一天成功过就不再发。
  ///
  /// 由启动流程在首帧之后的空闲任务里调用；所有失败都在这里收住，只写诊断，
  /// 不向界面抛错。
  Future<void> reportIfDue() async {
    try {
      if (!await store.enabled()) return;
      // 首次使用的说明看过之前不采集，避免用户还没被告知就开始上报。
      if (!await store.noticeSeen()) return;
      if (await signedIn()) return;
      final day = _dayOf(_clock());
      if (await store.lastReportDay() == day) return;
      final client = _clientFactory(await serverBaseUrl());
      try {
        await _send(client, await store.installId());
        await store.setLastReportDay(day);
      } finally {
        client.dispose();
      }
    } catch (error, stack) {
      crashLog.record(error, stack, kind: 'telemetry_report', report: false);
    }
  }

  /// 一次失败之后静默重试一次；仍失败时原样上抛，由 [reportIfDue] 记诊断。
  Future<void> _send(ServerClient client, String installId) async {
    try {
      await _post(client, installId);
    } catch (_) {
      await Future<void>.delayed(retryDelay);
      await _post(client, installId);
    }
  }

  Future<void> _post(ServerClient client, String installId) =>
      client.reportActive(
        installId: installId,
        appVersion: appVersion,
        platform: _platform(),
      );

  /// 设置页的开关；打开时立刻尝试一次，用户不必等到下次启动。
  Future<void> setEnabled(bool value) async {
    await store.setEnabled(value);
    if (value) unawaited(reportIfDue());
  }

  Future<bool> enabled() => store.enabled();

  Future<bool> noticeSeen() => store.noticeSeen();

  /// 首次说明的选择结果：记住说明看过，并按用户的选择决定是否上报。
  ///
  /// 选择保持开启时当场尝试一次上报；调用方在弹窗关闭之后才走到这里，等待这次
  /// 请求不会挡住用户操作。
  Future<void> completeNotice({required bool enabled}) async {
    await store.setEnabled(enabled);
    await store.markNoticeSeen();
    if (enabled) await reportIfDue();
  }

  static String _platform() =>
      Platform.isAndroid ? 'android' : Platform.operatingSystem;

  static String _dayOf(DateTime now) {
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }
}
