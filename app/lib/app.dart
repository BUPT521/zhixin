import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'ai/ai_chat_service.dart';
import 'app_scope.dart';
import 'domain/rules/time_policy.dart';
import 'data/diagnostics/crash_log.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';
import 'ui/theme_mode_controller.dart';

class ZhixinApp extends StatefulWidget {
  const ZhixinApp({
    super.key,
    this.crashLog,
    this.ai,
    this.themeMode,
    this.clock,
  });

  /// 启动时先建好的崩溃记录；测试或路径解析失败时为空。
  final CrashLog? crashLog;

  /// 回答来源；测试可以换成固定回答，为空时读取设置里的模型配置。
  final BuddyAi? ai;

  /// 启动前读到的外观；为空时跟随系统，测试与路径解析失败走这里。
  final ThemeModeController? themeMode;

  /// 时间来源；为空时取系统时钟，测试传固定时钟。
  final Clock? clock;

  @override
  State<ZhixinApp> createState() => _ZhixinAppState();
}

class _ZhixinAppState extends State<ZhixinApp> {
  late final ThemeModeController _themeMode =
      widget.themeMode ?? ThemeModeController();

  @override
  void dispose() {
    // 传进来的实例归 main 或调用方管；应用自己兜底建的那个才在这里释放。
    if (widget.themeMode == null) _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: '知新',
        debugShowCheckedModeBanner: false,
        theme: zhixinTheme,
        // 深浅色跟随系统，设置页可以把外观固定成浅色或深色。
        darkTheme: zhixinDarkTheme,
        themeMode: mode,
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
          data: Theme.brightnessOf(context) == Brightness.light
              ? zhixinForuiTheme
              : zhixinDarkForuiTheme,
          child: forui.FToaster(
            // 提示的位置与底部留白在主题里统一写好，各平台的短提示都落在下面。
            style: zhixinToasterStyle,
            child: AppScope(
              crashLog: widget.crashLog,
              ai: widget.ai,
              clock: widget.clock,
              themeMode: _themeMode,
              child: child!,
            ),
          ),
        ),
        home: const HomeShell(),
      ),
    );
  }
}
