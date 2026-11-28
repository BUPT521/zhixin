import 'dart:async';

import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'ai/ai_chat_service.dart';
import 'app_scope.dart';
import 'application/update_check_service.dart';
import 'data/cloud/server_client.dart' show ServerClient;
import 'domain/rules/time_policy.dart';
import 'data/diagnostics/crash_log.dart';
import 'platform/app_paths.dart';
import 'platform/first_frame.dart';
import 'platform/onboarding_store.dart';
import 'platform/theme_accent_store.dart';
import 'platform/theme_mode_store.dart';
import 'ui/home_shell.dart';
import 'ui/onboarding_consent.dart';
import 'ui/onboarding_controller.dart';
import 'ui/onboarding_page.dart';
import 'ui/theme.dart';
import 'ui/theme_accent_controller.dart';
import 'ui/theme_mode_controller.dart';

class ZhixinApp extends StatefulWidget {
  const ZhixinApp({
    super.key,
    this.crashLog,
    this.ai,
    this.themeMode,
    this.themeAccent,
    this.clock,
    this.spaces,
    this.spaceId = AppSpaces.local,
    this.serverClientFactory,
    this.onboardingStore,
    this.onboardingRecord,
    this.existingUser = false,
    this.signedIn = false,
    this.telemetryEnabled = true,
    this.updates,
  });

  /// 启动时先建好的崩溃记录；测试或路径解析失败时为空。
  final CrashLog? crashLog;

  /// 回答来源；测试可以换成固定回答，为空时读取设置里的模型配置。
  final BuddyAi? ai;

  /// 启动前读到的外观；为空时跟随系统，测试与路径解析失败走这里。
  final ThemeModeController? themeMode;

  /// 启动前读到的主题色；为空时用默认的蓝色。
  final ThemeAccentController? themeAccent;

  /// 时间来源；为空时取系统时钟，测试传固定时钟。
  final Clock? clock;
  final AppSpaces? spaces;
  final String spaceId;
  final ServerClient Function(String baseUrl)? serverClientFactory;

  /// 设备级引导状态；为空表示这条装配不经过首次启动引导（测试）。
  final OnboardingStore? onboardingStore;

  /// 启动时读到的引导状态；为空按全新安装处理。
  final OnboardingRecord? onboardingRecord;

  /// 升级前是否已经用过知新：已经登录、本机库非空或已经看过匿名统计说明。
  final bool existingUser;

  /// 启动时是否已经登录；中途退出引导之后据此直接到外观这一步。
  final bool signedIn;

  /// 匿名使用统计的当前开关；同意对话框按它显示，默认开启。
  final bool telemetryEnabled;

  /// 更新检查服务；测试注入计数用的替身，为空时按当前服务地址新建。
  final UpdateCheckService? updates;

  @override
  State<ZhixinApp> createState() => _ZhixinAppState();
}

class _ZhixinAppState extends State<ZhixinApp> {
  late ThemeModeController _themeMode =
      widget.themeMode ?? ThemeModeController();
  late ThemeAccentController _themeAccent =
      widget.themeAccent ?? ThemeAccentController();
  late String _spaceId = widget.spaceId;
  GlobalKey<AppScopeState> _scopeKey = GlobalKey<AppScopeState>();
  var _changingSpace = false;

  /// 首次启动引导的状态；为空时直接显示首页。
  OnboardingController? _onboarding;

  /// 引导状态写在设备级位置，设置页的同意入口也要写它。
  OnboardingStore? _onboardingStore;

  /// 联网开关：同意用户须知之后才打开，匿名上报与启动时的更新检查都看它。
  late final ValueNotifier<bool> _networkAllowed;

  @override
  void initState() {
    super.initState();
    _onboardingStore = widget.onboardingStore;
    final store = _onboardingStore;
    if (store == null) {
      _networkAllowed = ValueNotifier(true);
      return;
    }
    final record = widget.onboardingRecord ?? const OnboardingRecord();
    final entry = OnboardingController.entryFor(
      record,
      existingUser: widget.existingUser,
    );
    _networkAllowed = ValueNotifier(record.consentCurrent);
    if (entry == OnboardingEntry.home) return;
    _onboarding = OnboardingController(
      store: store,
      entry: entry,
      record: record,
      signedIn: widget.signedIn,
      telemetryEnabled: widget.telemetryEnabled,
    )..addListener(_onOnboardingChanged);
    // 引导不读数据库：首帧显示引导，原生启动图到现在就让位，开库在后台继续。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FirstFrameGate.release(),
    );
  }

  @override
  void dispose() {
    _onboarding?.removeListener(_onOnboardingChanged);
    _onboarding?.dispose();
    _networkAllowed.dispose();
    // 传进来的实例归 main 或调用方管；应用自己兜底建的那个才在这里释放。
    if (_themeMode != widget.themeMode) _themeMode.dispose();
    if (_themeAccent != widget.themeAccent) _themeAccent.dispose();
    super.dispose();
  }

  /// 引导状态变化：同步联网开关；走完之后让应用根部重建一次，把首页换回来
  /// 并让页面开始等首屏数据。
  void _onOnboardingChanged() {
    final controller = _onboarding;
    if (controller == null) return;
    final wasAllowed = _networkAllowed.value;
    if (wasAllowed != controller.networkAllowed) {
      _networkAllowed.value = controller.networkAllowed;
      if (!wasAllowed && controller.networkAllowed) {
        _resumeSyncAfterConsent();
      }
    }
    if (controller.finished && mounted) {
      setState(() {});
      _reportAfterOnboarding();
    }
  }

  /// 同意用户须知之后补一次自动同步调度。
  ///
  /// 应用启动时同意之前的自动同步被跳过；老用户升级到这一版时本机库已经登录
  /// 并可能积着待推送的提交，同意之后要接着推，不必等下一次启动。
  void _resumeSyncAfterConsent() {
    final scope = _scopeKey.currentState;
    if (scope == null) return;
    unawaited(
      scope.ready
          .then((_) async {
            if (!mounted || !_networkAllowed.value) return;
            await scope.accountServices.sync.schedule(
              delay: const Duration(seconds: 1),
            );
          })
          .catchError((Object _) {
            // 同步服务自己写诊断；这里只收住异步流程上的异常。
          }),
    );
  }

  /// 引导走完之后补一次匿名上报。
  ///
  /// 同意时只把说明状态与开关写进设备文件，不发请求；上报要在首页接上之后
  /// 才发出第一次上报，失败由服务静默写诊断。
  void _reportAfterOnboarding() {
    final scope = _scopeKey.currentState;
    if (scope == null || !_networkAllowed.value) return;
    unawaited(
      scope.ready
          .then((_) async {
            if (!mounted || !_networkAllowed.value) return;
            await scope.accountServices.activeReport.reportIfDue();
          })
          .catchError((Object _, StackTrace _) {
            // 上报服务自己写诊断；这里只收住异步流程上的异常。
          }),
    );
  }

  /// 设置页与账号页的同意入口：写当前版本的同意状态，并立即打开联网功能。
  Future<void> _agreeToTerms() async {
    final store = _onboardingStore;
    if (store == null) return;
    final record =
        _onboarding?.record ??
        widget.onboardingRecord ??
        const OnboardingRecord();
    await store.write(
      record.copyWith(
        completed: true,
        termsVersion: kTermsVersion,
        agreed: true,
      ),
    );
    _networkAllowed.value = true;
  }

  Future<void> _changeSpace(
    String id, {
    required bool adoptLocal,
    required bool deleteCurrent,
    String? label,
  }) async {
    if (id == _spaceId && !deleteCurrent) return;
    if (_changingSpace) throw StateError('正在切换本机空间');
    _changingSpace = true;
    final spaces = widget.spaces!;
    try {
      await _scopeKey.currentState?.closeSpace();
      if (deleteCurrent) await spaces.delete(_spaceId);
      await spaces.open(id, adoptLocal: adoptLocal, label: label);
      await _showSpace(id);
      // 第一次登录把未登录空间改成账号空间，页面随整棵树重建。引导停在哪一步
      // 已经写进设备文件，新的页面按登录态把登录这一步补成已完成，这里不直接推。
    } catch (_) {
      // 文件操作失败时重新打开原目录，页面可以重试。
      await _showSpace(_spaceId);
      rethrow;
    } finally {
      _changingSpace = false;
    }
  }

  Future<void> _showSpace(String id) async {
    final dir = widget.spaces!.pathsFor(id).filesDir;
    final (mode, accent) = await (
      ThemeModeController.load(ThemeModeStore(dir)),
      ThemeAccentController.load(ThemeAccentStore(dir)),
    ).wait;
    if (!mounted) {
      mode.dispose();
      accent.dispose();
      return;
    }
    final oldMode = _themeMode;
    final oldAccent = _themeAccent;
    setState(() {
      _spaceId = id;
      _themeMode = mode;
      _themeAccent = accent;
      _scopeKey = GlobalKey<AppScopeState>();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (oldMode != widget.themeMode) oldMode.dispose();
      if (oldAccent != widget.themeAccent) oldAccent.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 只有完整两步会遮住首页：老用户与须知改版在首页上补同意，首页照常先显示。
    final showingOnboarding =
        _onboarding != null &&
        !_onboarding!.finished &&
        _onboarding!.entry == OnboardingEntry.full;
    return ListenableBuilder(
      listenable: Listenable.merge([_themeMode, _themeAccent]),
      builder: (context, _) {
        final accent = _themeAccent.value;
        final material = materialThemesFor(accent);
        final foruiThemes = foruiThemesFor(accent);
        return MaterialApp(
          key: ObjectKey(_scopeKey),
          title: '知新',
          debugShowCheckedModeBanner: false,
          theme: material[Brightness.light],
          // 深浅色跟随系统，设置页可以把外观固定成浅色或深色；主题色另有
          // 六个选项，深浅两套各有一份主色，其余色值不随主题色改变。
          darkTheme: material[Brightness.dark],
          themeMode: _themeMode.value,
          // 界面是中文的，Material 自带的日期选择、长按菜单等也跟着走中文。
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            forui.FLocalizations.delegate,
          ],
          // FTheme 放到 AppScope 外面：应用根自己的加载与出错页也要用同一套
          // Forui 主题，FToaster 则要包住整个导航树，页面里的提示才找得到它。
          builder: (context, child) => forui.FTheme(
            data: foruiThemes[Theme.of(context).brightness]!,
            child: forui.FToaster(
              // 提示的位置与底部留白在主题里统一写好，各平台的短提示都落在下面。
              style: zhixinToasterStyle,
              child: AppScope(
                key: _scopeKey,
                spaces: widget.spaces,
                spaceId: _spaceId,
                changeSpace: widget.spaces == null ? null : _changeSpace,
                serverClientFactory: widget.serverClientFactory,
                crashLog: widget.crashLog,
                ai: widget.ai,
                clock: widget.clock,
                themeMode: _themeMode,
                themeAccent: _themeAccent,
                // 有引导装配时才加这层开关；测试等没有引导的装配保持原来的样子。
                networkAllowed: _onboardingStore == null
                    ? null
                    : _networkAllowed,
                onAgreeTerms: _onboardingStore == null ? null : _agreeToTerms,
                updates: widget.updates,
                // 完整引导只需要本地状态：先不等开库，第一帧就能显示登录页；
                // 在首页补同意时首页本身要等数据，照常等。
                waitForData: !showingOnboarding,
                child: child!,
              ),
            ),
          ),
          home: _AppHome(onboarding: _onboarding),
        );
      },
    );
  }
}

/// 应用根部选择的首页：引导没走完时显示引导，走完直接换成现有的首页；老用户
/// 与须知改版直接显示首页，再在首页上弹一次同意。
///
/// 不把引导做成压在首页之上的路由：`HomeShell` 的首次说明与更新检查在页面
/// 一建起来就会安排，做成路由会让它们在用户同意之前先跑。
class _AppHome extends StatelessWidget {
  const _AppHome({this.onboarding});

  final OnboardingController? onboarding;

  @override
  Widget build(BuildContext context) {
    final controller = onboarding;
    if (controller == null) return const HomeShell();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.finished) return const HomeShell();
        if (controller.termsOnly) return _ConsentOnHome(controller: controller);
        return OnboardingPage(controller: controller);
      },
    );
  }
}

/// 首页上的补同意：首页照常显示，首帧之后再弹同意对话框。
///
/// 老用户与须知改版走这一条，首页在同意之前不联网（`networkAllowed` 为假），
/// 关掉对话框就留在纯本机模式，之后可以在设置页的同意入口补上。
class _ConsentOnHome extends StatefulWidget {
  const _ConsentOnHome({required this.controller});

  final OnboardingController controller;

  @override
  State<_ConsentOnHome> createState() => _ConsentOnHomeState();
}

class _ConsentOnHomeState extends State<_ConsentOnHome> {
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask());
  }

  Future<void> _ask() async {
    if (_asked || !mounted) return;
    _asked = true;
    if (widget.controller.record.consentCurrent) return;
    try {
      await ensureOnboardingConsent(
        context,
        controller: widget.controller,
        report: true,
      );
      // 回答过这次询问（同意或只在本机）就写完成标记：下次启动直接进首页，
      // 不再因为没走完引导把老用户带回登录页。
      if (widget.controller.record.termsVersion >= kTermsVersion) {
        await widget.controller.finish();
      }
    } catch (_) {
      // 同意状态写不进去时留在纯本机模式，设置页的同意入口可以再试一次。
    }
  }

  @override
  Widget build(BuildContext context) => const HomeShell();
}
