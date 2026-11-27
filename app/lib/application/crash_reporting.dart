/// 崩溃报告开关的读写端口。
///
/// 开关存在设备级的小文件里，读写由平台层实现（`platform/diagnostics_store.dart`），
/// 应用层只按这个接口取用：设置页经 `SettingsService` 打开或关闭上报，不直接
/// 碰数据层与平台层，应用层也不引 `package:flutter` 与 `dart:io`。
abstract interface class CrashReportingSwitch {
  /// 当前取值；文件不存在、损坏或读不出来时返回 [fallback]。
  Future<bool> read({bool fallback = true});

  /// 写入新取值。
  Future<void> write(bool enabled);
}
