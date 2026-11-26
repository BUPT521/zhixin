import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'application/sync_service.dart' show syncScopeFor;
import 'data/cloud/account_store.dart';
import 'data/cloud/cloud_preferences_store.dart';
import 'data/cloud/server_client.dart' show ServerClient;
import 'data/cloud/telemetry_store.dart';
import 'data/diagnostics/crash_log.dart';
import 'platform/app_license.dart';
import 'platform/app_paths.dart';
import 'platform/diagnostics_store.dart';
import 'platform/first_frame.dart';
import 'platform/legacy_layout.dart';
import 'platform/onboarding_store.dart';
import 'platform/prompt_assets.dart';
import 'platform/secure_secret_store.dart';
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
  // 0.2.0 的单体布局不再读取，第一次启动时删除；删不掉的条目记进诊断，
  // 不阻断启动，下次启动再试。
  if (paths != null) await _deleteLegacyLayout(paths.filesDir, crashLog);
  // 提示词在启动时读一次；读取失败只影响模型回答，本机功能照常可用。
  await _loadPromptText(crashLog);
  final spaces = paths == null ? null : AppSpaces(paths);
  final opened = spaces == null
      ? null
      : await _readOrNull(() => _openStartupSpace(spaces));
  final spaceId = opened?.id ?? AppSpaces.local;
  final appearance = spaces == null
      ? null
      : await _loadAppearance(spaces.pathsFor(spaceId));
  // 引导状态存在设备级位置（ADR-0077）：完成标记、同意的须知版本与是否同意
  // 三项都在根目录的小文件里，不随本机空间切换。
  final onboardingStore = paths == null
      ? null
      : OnboardingStore(paths.filesDir);
  final onboarding = onboardingStore == null
      ? null
      : await _readOrNull(onboardingStore.read) ?? const OnboardingRecord();
  final telemetry = paths == null
      ? null
      : await _readOrNull(() async {
          final store = TelemetryStore(filesDir: paths.filesDir);
          return (
            enabled: await store.enabled(),
            seen: await store.noticeSeen(),
          );
        });
  // 老用户升级：没有完成标记，但已经登录、本机库非空或已经看过匿名统计说明，
  // 只补第一步。本机库按数据库文件是否已经存在判断，引导本身不读库。
  final existingUser =
      spaces != null &&
      paths != null &&
      await _looksLikeExistingUser(
        spaces,
        spaceId,
        signedIn: opened?.signedIn ?? false,
        filesDir: paths.filesDir,
        noticeSeen: telemetry?.seen ?? false,
      );
  final reporting =
      paths != null &&
      await DiagnosticsStore(paths.filesDir).read(fallback: !kReleaseMode);
  CrashLog.reportEnabled = reporting;

  void run() => runApp(
    ZhixinApp(
      crashLog: crashLog,
      themeMode: appearance?.themeMode,
      themeAccent: appearance?.themeAccent,
      spaces: spaces,
      spaceId: spaceId,
      onboardingStore: onboardingStore,
      onboardingRecord: onboarding,
      existingUser: existingUser,
      signedIn: opened?.signedIn ?? false,
      telemetryEnabled: telemetry?.enabled ?? true,
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

Future<({String id, bool signedIn})> _openStartupSpace(AppSpaces spaces) async {
  final previous = await spaces.lastOpened();
  final preferences = CloudPreferencesStore(filesDir: spaces.device.filesDir);
  final origin = ServerClient.originOf(await preferences.serverBaseUrl());
  final accounts = AccountStore(SecureSecretStore());
  final session = await accounts.read(origin: origin);
  final profile = session == null
      ? null
      : await accounts.readProfile(origin: origin);
  final signedIn = session != null && !session.isExpired;
  final id = !signedIn ? AppSpaces.local : syncScopeFor(session.userId, origin);
  await spaces.open(
    id,
    adoptLocal: previous == AppSpaces.local,
    label:
        id == AppSpaces.local || profile == null || profile.displayLabel.isEmpty
        ? null
        : '${profile.displayLabel} · ${Uri.parse(origin).authority}',
  );
  return (id: id, signedIn: signedIn);
}

/// 升级前是否已经用过知新。
///
/// 引导本身不读数据库：已登录、本机库文件已经存在或已经看过匿名统计说明，都
/// 说明这台设备以前用过应用，只让用户补第一步。全新安装时这三项都不成立。
Future<bool> _looksLikeExistingUser(
  AppSpaces spaces,
  String spaceId, {
  required bool signedIn,
  required String filesDir,
  required bool noticeSeen,
}) async {
  if (signedIn || noticeSeen) return true;
  try {
    return File(spaces.pathsFor(spaceId).dbPath).existsSync();
  } catch (_) {
    return false;
  }
}

/// 删除 0.2.0 留在应用私有目录根下的学习数据。
///
/// 旧布局的库、图片、检索索引、恢复点与临时备份都属于升级前的本机数据，
/// 0.3.0 不再读取；删除失败只记一条本机诊断，不影响启动与当前空间。
Future<void> _deleteLegacyLayout(String filesDir, CrashLog? crashLog) async {
  try {
    await deleteLegacyLayoutData(
      filesDir,
      onFailure: (name, error, stack) =>
          crashLog?.record(error, stack, kind: 'legacy_layout', report: false),
    );
  } catch (error, stack) {
    crashLog?.record(error, stack, kind: 'legacy_layout', report: false);
  }
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
