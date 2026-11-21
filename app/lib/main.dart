import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'data/diagnostics/crash_log.dart';
import 'platform/app_license.dart';
import 'platform/app_paths.dart';
import 'platform/diagnostics_store.dart';
import 'platform/first_frame.dart';
import 'platform/prompt_assets.dart';
import 'platform/theme_accent_store.dart';
import 'platform/theme_mode_store.dart';
import 'platform/zvec_license.dart';
import 'ui/theme_accent_controller.dart';
import 'ui/theme_mode_controller.dart';

/// 压住第一帧的上限：超过这个时间就露出加载页，不让用户停在一张不会动的
/// 启动图上等下去。
const Duration firstFrameLimit = Duration(milliseconds: 1500);

const String _sentryDsn = String.fromEnvironment('SENTRY_DSN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 原生启动图直接接上首页：先压住第一帧，AppScope 准备好首屏数据后再放行。
  // 开库比上限还慢时由下面这个定时器兜底，露出加载页。
  FirstFrameGate.defer();
  Timer(firstFrameLimit, FirstFrameGate.release);
  registerAppLicense();
  registerZvecLicense();
  final paths = await _resolvePaths();
  final crashLog = paths == null ? null : CrashLog(filesDir: paths.filesDir);
  if (crashLog != null) _installErrorHandlers(crashLog);
  // 提示词在启动时读一次；读取失败只影响模型回答，本机功能照常可用。
  await _loadPromptText(crashLog);
  final appearance = paths == null ? null : await _loadAppearance(paths);
  final reporting =
      paths != null &&
      await DiagnosticsStore(paths.filesDir).read(fallback: !kReleaseMode);
  CrashLog.reportEnabled = reporting;

  void run() => runApp(
    ZhixinApp(
      crashLog: crashLog,
      themeMode: appearance?.themeMode,
      themeAccent: appearance?.themeAccent,
    ),
  );

  // 没有 DSN 或用户关闭上报时，不初始化 Sentry，也不产生任何请求。
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
    options.enableNativeCrashHandling = false;
    options.enableAutoNativeBreadcrumbs = false;
    options.enablePrintBreadcrumbs = false;
    options.maxBreadcrumbs = 0;
    options.attachScreenshot = false;
    options.attachViewHierarchy = false;
    options.beforeSend = prepareCrashReport;
  }, appRunner: run);
}

/// 崩溃记录与外观都要赶在界面起来之前就位，所以路径在 main 里先解析一次；
/// 失败就不记录，外观退回跟随系统与默认的蓝色主题，不能因为这几件事让应用
/// 起不来。
Future<AppPaths?> _resolvePaths() async {
  try {
    return await AppPaths.resolve();
  } catch (_) {
    return null;
  }
}

/// 启动前读到的外观：深浅色与主题色各读一次，任一项读不出来时该项为空，
/// 由应用根部回到默认值。
Future<({ThemeModeController? themeMode, ThemeAccentController? themeAccent})>
_loadAppearance(AppPaths paths) async {
  final mode = await _readOrNull(
    () => ThemeModeController.load(ThemeModeStore(paths.filesDir)),
  );
  final accent = await _readOrNull(
    () => ThemeAccentController.load(ThemeAccentStore(paths.filesDir)),
  );
  return (themeMode: mode, themeAccent: accent);
}

Future<T?> _readOrNull<T>(Future<T> Function() read) async {
  try {
    return await read();
  } catch (_) {
    return null;
  }
}

/// 提示词资源缺失时不让应用起不来：本机记录、检索与导出都不依赖模型，
/// 失败记进诊断记录，回答时按本地兜底处理。
Future<void> _loadPromptText(CrashLog? crashLog) async {
  try {
    await PromptAssets.load();
  } catch (error, stack) {
    crashLog?.record(error, stack, kind: 'prompt_text', report: false);
  }
}

void _installErrorHandlers(CrashLog log) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    log.record(
      details.exception,
      details.stack,
      kind: 'framework',
      report: false,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    log.record(error, stack, kind: 'platform', report: false);
    // 记录下来之后仍交给引擎处理，崩溃率才不会因为吞掉错误而偏低。
    return false;
  };
}
