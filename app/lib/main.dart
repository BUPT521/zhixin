import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'data/diagnostics/crash_log.dart';
import 'platform/app_license.dart';
import 'platform/app_paths.dart';
import 'platform/diagnostics_store.dart';
import 'platform/theme_mode_store.dart';
import 'ui/theme_mode_controller.dart';

const String _sentryDsn = String.fromEnvironment('SENTRY_DSN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppLicense();
  final paths = await _resolvePaths();
  final crashLog = paths == null ? null : CrashLog(filesDir: paths.filesDir);
  if (crashLog != null) _installErrorHandlers(crashLog);
  final themeMode = paths == null ? null : await _loadThemeMode(paths);
  final reporting = paths == null
      ? !kReleaseMode
      : await DiagnosticsStore(paths.filesDir).read(fallback: !kReleaseMode);
  CrashLog.reportEnabled = reporting;

  void run() => runApp(ZhixinApp(crashLog: crashLog, themeMode: themeMode));

  // 没有注入 DSN 的构建（本地、PR）不初始化 Sentry，也不产生任何请求。
  if (_sentryDsn.isEmpty || !reporting) {
    run();
    return;
  }
  await SentryFlutter.init((options) {
    options.dsn = _sentryDsn;
    options.sendDefaultPii = false;
    options.tracesSampleRate = 0;
    options.environment = kReleaseMode ? 'release' : 'dev';
    options.enableAutoSessionTracking = true;
  }, appRunner: run);
}

/// 崩溃记录与外观都要赶在界面起来之前就位，所以路径在 main 里先解析一次；
/// 失败就不记录、外观退回跟随系统，不能因为这两件事让应用起不来。
Future<AppPaths?> _resolvePaths() async {
  try {
    return await AppPaths.resolve();
  } catch (_) {
    return null;
  }
}

Future<ThemeModeController?> _loadThemeMode(AppPaths paths) async {
  try {
    return await ThemeModeController.load(ThemeModeStore(paths.filesDir));
  } catch (_) {
    return null;
  }
}

void _installErrorHandlers(CrashLog log) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.record(details.exception, details.stack, kind: 'framework');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.record(error, stack, kind: 'platform');
    // 记录下来之后仍交给引擎处理，崩溃率才不会因为吞掉错误而偏低。
    return false;
  };
}
