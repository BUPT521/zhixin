import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'ai/ai_chat_service.dart';
import 'app_scope.dart';
import 'data/cloud/server_client.dart' show ServerClient;
import 'domain/rules/time_policy.dart';
import 'data/diagnostics/crash_log.dart';
import 'platform/app_paths.dart';
import 'platform/theme_accent_store.dart';
import 'platform/theme_mode_store.dart';
import 'ui/home_shell.dart';
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
  void dispose() {
    // 传进来的实例归 main 或调用方管；应用自己兜底建的那个才在这里释放。
    if (_themeMode != widget.themeMode) _themeMode.dispose();
    if (_themeAccent != widget.themeAccent) _themeAccent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                child: child!,
              ),
            ),
          ),
          home: const HomeShell(),
        );
      },
    );
  }
}
