import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 应用级标识；版本与构建号取自 Flutter 构建元数据，pubspec.yaml 是默认来源。
const String appName = '知新';

/// 开发包在版本名后加 -dev，与正式包区分；关于页、设置页与缺陷记录都看这一串。
final String appVersion =
    '${appBuildName ?? 'unknown'}${kDebugMode ? '-dev' : ''}+'
    '${appBuildNumber ?? 'unknown'}';
