import 'package:zhixin/data/cloud/telemetry_store.dart';

/// 让全应用用例跳过首次使用说明，并停掉匿名上报。
///
/// 统计与本机行为无关，但首次说明是弹窗、上报会走网络：两者都会干扰导航与
/// 输入用例，所以在这些用例里一律先关掉。首次说明本身在
/// `test/ui/telemetry_notice_test.dart` 单独覆盖。
Future<void> disableTelemetryForTests(String filesDir) async {
  final store = TelemetryStore(filesDir: filesDir);
  await store.markNoticeSeen();
  await store.setEnabled(false);
}
