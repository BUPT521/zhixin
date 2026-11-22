import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 应用级标识；版本与构建号取自 Flutter 构建元数据，pubspec.yaml 是默认来源。
const String appName = '知新';

/// 本机构建写入的提交编号；官方 CI 构建与 `flutter run` 没有传时为空串。
///
/// 取值来自 `tool/build_debug.ps1` 的 `--dart-define=ZHIXIN_COMMIT=...`，异常退出
/// 时保留在工作区的 `last_build.json` 里，两边读的是同一串（[buildCommit]）。
const String _buildCommit = String.fromEnvironment('ZHIXIN_COMMIT');

/// 构建时仓库的提交编号，前 7 位；没有写入时为空串。
final String buildCommit = _normalizeCommit(_buildCommit);

/// 开发包在版本名后加 -dev，与正式包区分；关于页、设置页与缺陷记录都看这一串。
final String appVersion =
    '${appBuildName ?? 'unknown'}${kDebugMode ? '-dev' : ''}+'
    '${appBuildNumber ?? 'unknown'}';

/// 界面上显示的版本串：开发包带提交编号，例如 `0.2.0-dev+3·a1b2c3d`。
///
/// 提交编号用中点接在构建号之后，不带 `-`、`_` 与 `+`，因为 `ReleaseVersion`
/// 只把第一段 `+` 之后当作构建号，后两种写法会让更新检查解析失败。
final String appVersionLabel = buildCommit.isEmpty
    ? appVersion
    : '$appVersion·$buildCommit';

/// 只接受 7–40 位十六进制；别的值当作没有写入，不塞进版本串。
String _normalizeCommit(String value) {
  final input = value.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{7,40}$').hasMatch(input)) return '';
  return input.substring(0, 7);
}
