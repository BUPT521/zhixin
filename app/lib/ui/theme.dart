import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:forui/forui.dart' as forui;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';

import 'motion.dart';

export 'motion.dart';

/// 应用的两套外观：色值与字号只在这里定义一次，Forui 主题、页面读到的
/// 字号与颜色、回答正文的 Markdown 主题都从同一份生成。
///
/// 页面不再读 Material 的 `Theme.of`，统一读 Forui 主题里的 [ZhixinTheme]；
/// Material 的 `ThemeData` 只留给 `gpt_markdown`（它要 `GptMarkdownThemeData`
/// 与 `TextTheme`）和本地化，不再是一份需要单独维护的色板。
const _Palette _lightPalette = _Palette(
  brightness: Brightness.light,
  ink: Color(0xFF203C35),
  muted: Color(0xFF6B7280),
  paper: Color(0xFFF5F7F3),
  card: Color(0xFFFFFFFF),
  code: Color(0xFFFFFFFF),
  border: Color(0xFFE4EAE3),
  inputBorder: Color(0xFFDAE3DA),
  moss: Color(0xFF286653),
  mossLight: Color(0xFFE0EDE3),
  mossContainer: Color(0xFFCEE9DC),
  onMossContainer: Color(0xFF344C43),
  raised: Color(0xFFE4EAE5),
  clay: Color(0xFFB4593C),
  clayLight: Color(0xFFF6E7E0),
  onClayLight: Color(0xFF7A3520),
  onAccent: Color(0xFFFFFFFF),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
);

const _Palette _darkPalette = _Palette(
  brightness: Brightness.dark,
  ink: Color(0xFFE3EAE5),
  muted: Color(0xFFA3B1A9),
  paper: Color(0xFF121815),
  card: Color(0xFF1C2420),
  code: Color(0xFF141C18),
  border: Color(0xFF2F3C36),
  inputBorder: Color(0xFF3C4B44),
  moss: Color(0xFF8FCDB4),
  mossLight: Color(0xFF27443A),
  mossContainer: Color(0xFF344C42),
  onMossContainer: Color(0xFFCEE9DB),
  raised: Color(0xFF252B28),
  clay: Color(0xFFE2A58C),
  clayLight: Color(0xFF412A21),
  onClayLight: Color(0xFFF3CDBD),
  onAccent: Color(0xFF12231C),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
);

final forui.FThemeData zhixinForuiTheme = _buildForui(_lightPalette);
final forui.FThemeData zhixinDarkForuiTheme = _buildForui(_darkPalette);

/// 回答正文与 Material 本地化用的主题；页面不再从它取字号与颜色。
final ThemeData zhixinTheme = _buildMaterial(_lightPalette);
final ThemeData zhixinDarkTheme = _buildMaterial(_darkPalette);

const _controlRadius = Radius.circular(12);
const _cardRadius = Radius.circular(20);

/// 页面里的字号与颜色；从 Forui 主题的应用扩展读取。
extension ZhixinThemeContext on BuildContext {
  ZhixinTheme get zhixin => forui.FTheme.of(this).extension<ZhixinTheme>();
}

/// 页面与表单共用的字号、行高与字重，数值与原来的 Material 文本样式一致。
class ZhixinTextStyles {
  const ZhixinTextStyles({
    required this.headlineMedium,
    required this.headlineSmall,
    required this.titleLarge,
    required this.titleMedium,
    required this.titleSmall,
    required this.bodyLarge,
    required this.bodyMedium,
    required this.bodySmall,
    required this.labelLarge,
    required this.labelMedium,
    required this.labelSmall,
    required this.figures,
  });

  /// 时刻、时长与计数用的等宽数字；日程里上下对齐的时间读这一份。
  final TextStyle figures;

  final TextStyle headlineMedium;
  final TextStyle headlineSmall;
  final TextStyle titleLarge;
  final TextStyle titleMedium;
  final TextStyle titleSmall;
  final TextStyle bodyLarge;
  final TextStyle bodyMedium;
  final TextStyle bodySmall;
  final TextStyle labelLarge;
  final TextStyle labelMedium;
  final TextStyle labelSmall;
}

/// 页面需要的颜色角色；色值来自 [_Palette]，与 Material 的 `ColorScheme` 同名同值。
class ZhixinColors {
  const ZhixinColors({
    required this.primary,
    required this.onPrimary,
    required this.onSurface,
    required this.error,
    required this.onError,
    required this.secondary,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.surface,
    required this.surfaceContainerHigh,
    required this.card,
    required this.attention,
    required this.attentionContainer,
    required this.onAttentionContainer,
  });

  /// 需要用户留意的状态，例如未提交的草稿与优先事项；与 [secondary] 同值。
  final Color attention;

  /// 留意状态的浅底，用在草稿与优先标签上。
  final Color attentionContainer;

  /// 压在 [attentionContainer] 上的文字颜色。
  final Color onAttentionContainer;

  final Color primary;

  /// 压在主色上的文字与图标，例如首页当前活动卡。
  final Color onPrimary;
  final Color onSurface;
  final Color error;
  final Color onError;
  final Color secondary;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color surface;
  final Color surfaceContainerHigh;
  final Color card;
}

/// 页面留白的几档取值；页面与公共组件只从这里取，不再各写一套数字。
class ZhixinSpace {
  const ZhixinSpace();

  /// 同一行里图标与文字、标签与标签之间。
  double get xs => 4;

  /// 同一张卡片里相邻两行之间。
  double get sm => 8;

  /// 列表里相邻两张卡片之间、卡片内边距的短边。
  double get md => 12;

  /// 卡片内边距。
  double get lg => 16;

  /// 页面左右边距。
  double get page => 20;

  /// 空态与对话框这类需要松一些的内边距。
  double get xl => 24;

  /// 相邻两节之间。
  double get section => 28;

  /// 内容区的最大宽度；平板与横屏上居中，不把一行拉得过长。
  double get maxWidth => 720;
}

/// 圆角的三档：控件、列表卡片与强调卡片。
class ZhixinRadius {
  const ZhixinRadius();

  /// 标签与小按钮。
  BorderRadius get tag => const BorderRadius.all(Radius.circular(8));

  /// 列表里的卡片与输入框；与 FCard、卡片主题取同一个半径。
  BorderRadius get card => const BorderRadius.all(_cardRadius);

  /// 首页当前活动与输入区这类一页只出现一次的卡片。
  BorderRadius get feature => const BorderRadius.all(Radius.circular(24));
}

/// Forui 主题上的应用扩展：页面读它，不再读 Material 的 `Theme.of`。
class ZhixinTheme extends ThemeExtension<ZhixinTheme> {
  const ZhixinTheme({
    required this.text,
    required this.colors,
    this.space = const ZhixinSpace(),
    this.radius = const ZhixinRadius(),
    this.motion = const ZhixinMotion(),
  });

  final ZhixinTextStyles text;
  final ZhixinColors colors;

  final ZhixinSpace space;
  final ZhixinRadius radius;
  final ZhixinMotion motion;

  @override
  ThemeExtension<ZhixinTheme> copyWith() => this;

  @override
  ThemeExtension<ZhixinTheme> lerp(
    covariant ThemeExtension<ZhixinTheme>? other,
    double t,
  ) => other is ZhixinTheme && t >= 0.5 ? other : this;
}

forui.FThemeData _buildForui(_Palette palette) {
  final base = palette.brightness == Brightness.light
      ? forui.FTheme.neutral.light.touch
      : forui.FTheme.neutral.dark.touch;
  final colors = base.colors.copyWith(
    background: palette.paper,
    foreground: palette.ink,
    primary: palette.moss,
    primaryForeground: palette.onAccent,
    secondary: palette.mossLight,
    secondaryForeground: palette.ink,
    mutedForeground: palette.muted,
    card: palette.card,
    border: palette.border,
    error: palette.error,
    errorForeground: palette.onError,
    destructive: palette.error,
    destructiveForeground: palette.onError,
  );
  final text = _textStyles(palette);
  return forui.FThemeData(
    colors: colors,
    typography: base.typography.copyWith(
      // Forui 的表单与列表按 body.sm 排正文；原来按 Material 的 bodyMedium 折算，
      // 这里继续取同一份字号，避免两处文字大小不同。
      body: base.typography.body.copyWith(sm: text.bodyMedium),
    ),
    style: base.style.copyWith(
      borderRadius: base.style.borderRadius.copyWith(
        md: const BorderRadius.all(_controlRadius),
      ),
    ),
    // Forui 的卡片默认取自家的半径刻度（14），与页面里读到的卡片圆角（20）
    // 不同；这里按同一份取值改，卡片与气泡的圆角才一致。
    cardStyle: base.cardStyle.copyWith(
      decoration: forui.DecorationDelta.shapeDelta(
        shape: RoundedSuperellipseBorder(
          borderRadius: const BorderRadius.all(_cardRadius),
          side: BorderSide(color: colors.border, width: base.style.borderWidth),
        ),
      ),
    ),
    // 页面自己按 ZhixinSpace 留白，FScaffold 再加一层页边距会让同一页出现
    // 两层留白；这里统一把默认内边距设为零，页面不必逐个传 childPad: false。
    scaffoldStyle: base.scaffoldStyle.copyWith(
      childPadding: forui.EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
    ),
    touch: true,
    extensions: [ZhixinTheme(text: text, colors: _colors(palette))],
  );
}

ZhixinTextStyles _textStyles(_Palette palette) {
  TextStyle style({
    required double fontSize,
    required double height,
    required double letterSpacing,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(
    // 与 Forui 控件同一个字族：原来页面文字落到系统默认字体，按钮与输入框
    // 用 Inter，同一屏里的数字与字母两种字形；中文仍由系统字体补齐。
    fontFamily: forui.FTypeface.defaultFontFamily,
    fontSize: fontSize,
    height: height,
    letterSpacing: letterSpacing,
    fontWeight: weight,
    color: palette.ink,
  );

  return ZhixinTextStyles(
    figures: style(
      fontSize: 14,
      height: 1.3,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    headlineMedium: style(
      fontSize: 28,
      height: 1.29,
      letterSpacing: -0.5,
      weight: FontWeight.w700,
    ),
    headlineSmall: style(
      fontSize: 24,
      height: 1.33,
      letterSpacing: 0,
      weight: FontWeight.w700,
    ),
    titleLarge: style(fontSize: 22, height: 1.27, letterSpacing: 0),
    titleMedium: style(
      fontSize: 16,
      height: 1.5,
      letterSpacing: 0.15,
      weight: FontWeight.w600,
    ),
    titleSmall: style(
      fontSize: 14,
      height: 1.43,
      letterSpacing: 0.1,
      weight: FontWeight.w600,
    ),
    bodyLarge: style(fontSize: 16, height: 1.5, letterSpacing: 0.5),
    bodyMedium: style(fontSize: 14, height: 1.5, letterSpacing: 0.25),
    bodySmall: style(fontSize: 12, height: 1.45, letterSpacing: 0.4),
    labelLarge: style(
      fontSize: 14,
      height: 1.43,
      letterSpacing: 0.1,
      weight: FontWeight.w500,
    ),
    labelMedium: style(
      fontSize: 12,
      height: 1.33,
      letterSpacing: 0.5,
      weight: FontWeight.w500,
    ),
    labelSmall: style(
      fontSize: 11,
      height: 1.45,
      letterSpacing: 0.5,
      weight: FontWeight.w500,
    ),
  );
}

ZhixinColors _colors(_Palette palette) => ZhixinColors(
  primary: palette.moss,
  onPrimary: palette.onAccent,
  onSurface: palette.ink,
  error: palette.error,
  onError: palette.onError,
  secondary: palette.clay,
  onSurfaceVariant: palette.muted,
  outline: palette.inputBorder,
  outlineVariant: palette.border,
  primaryContainer: palette.mossLight,
  onPrimaryContainer: palette.ink,
  secondaryContainer: palette.mossContainer,
  onSecondaryContainer: palette.onMossContainer,
  surface: palette.paper,
  surfaceContainerHigh: palette.raised,
  card: palette.card,
  attention: palette.clay,
  attentionContainer: palette.clayLight,
  onAttentionContainer: palette.onClayLight,
);

/// gpt_markdown 仍按 Material 的 `ThemeData` 取样式与 `GptMarkdownThemeData`，
/// 这里用它需要的那部分，色值与字号同样来自 [_Palette] 与 [_textStyles]。
ThemeData _buildMaterial(_Palette palette) {
  final colors =
      ColorScheme.fromSeed(
        seedColor: palette.moss,
        brightness: palette.brightness,
        primary: palette.moss,
        secondary: palette.clay,
        surface: palette.paper,
      ).copyWith(
        primaryContainer: palette.mossLight,
        onPrimaryContainer: palette.ink,
        onSurface: palette.ink,
        onSurfaceVariant: palette.muted,
        outline: palette.inputBorder,
        outlineVariant: palette.border,
        secondaryContainer: palette.mossContainer,
        onSecondaryContainer: palette.onMossContainer,
        surfaceContainerHigh: palette.raised,
        error: palette.error,
        onError: palette.onError,
      );
  final base = ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: palette.paper,
  );
  final text = _textStyles(palette);
  return base.copyWith(
    // 页面路由的过渡在这里配一次，各页不再各写一套：安卓与桌面用淡入加
    // 右推，iOS 保留系统的滑回手势。减少动态效果时由 builder 直接给终态。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZhixinPageTransitionsBuilder(),
        TargetPlatform.fuchsia: ZhixinPageTransitionsBuilder(),
        TargetPlatform.linux: ZhixinPageTransitionsBuilder(),
        TargetPlatform.windows: ZhixinPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    // 底部面板改用 Material 之后，底色、上圆角与拖动条从这里取；页面打开
    // 面板时只写 showDragHandle 等行为，不再各配一遍样式。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.card,
      modalBackgroundColor: palette.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      dragHandleColor: palette.border,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: _cardRadius),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    textTheme: base.textTheme.copyWith(
      headlineMedium: text.headlineMedium,
      headlineSmall: text.headlineSmall,
      titleLarge: text.titleLarge,
      titleMedium: text.titleMedium,
      titleSmall: text.titleSmall,
      bodyLarge: text.bodyLarge,
      bodyMedium: text.bodyMedium,
      bodySmall: text.bodySmall,
      labelLarge: text.labelLarge,
      labelMedium: text.labelMedium,
      labelSmall: text.labelSmall,
    ),
    // 回答正文的 Markdown 与界面共用一套颜色和字号：标题压到聊天气泡能用的
    // 级别，链接用苔绿、悬停用陶土色，不再落到组件默认的蓝色。
    extensions: <ThemeExtension<dynamic>>[
      GptMarkdownThemeData(
        brightness: palette.brightness,
        linkColor: palette.moss,
        linkHoverColor: palette.clay,
        // 聊天里的 h1 不画文档式分隔线。
        autoAddDividerLineAfterH1: false,
        h1: text.titleLarge.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
        h2: text.titleMedium.copyWith(fontSize: 17, height: 1.35),
        h3: text.titleSmall.copyWith(fontSize: 15, height: 1.35),
        h4: text.bodyMedium.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        h5: text.bodyMedium.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        h6: text.bodySmall.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        styleSheet: GptMarkdownStyleSheet(
          table: TableStyle(
            borderColor: palette.border,
            borderWidth: 1,
            borderRadius: const Radius.circular(12),
            cellPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 6,
            ),
            headerBackground: palette.mossLight,
            headerTextStyle: text.bodyMedium.copyWith(
              fontWeight: FontWeight.w600,
            ),
            overflow: TableOverflow.wrap,
          ),
          codeBlock: CodeBlockStyle(
            backgroundColor: palette.code,
            borderColor: palette.border,
            borderWidth: 1,
            borderRadius: const Radius.circular(12),
            // 围栏没闭合前不逐片高亮，闭合后再上色。
            highlightWhileStreaming: false,
          ),
          blockQuote: BlockQuoteStyle(
            barColor: palette.moss,
            backgroundColor: palette.paper,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            margin: const EdgeInsets.symmetric(vertical: 4),
          ),
        ),
      ),
    ],
  );
}

/// 同一套界面要用的颜色角色；深浅两套只改这里的色值。
class _Palette {
  const _Palette({
    required this.brightness,
    required this.ink,
    required this.muted,
    required this.paper,
    required this.card,
    required this.code,
    required this.border,
    required this.inputBorder,
    required this.moss,
    required this.mossLight,
    required this.mossContainer,
    required this.onMossContainer,
    required this.raised,
    required this.clay,
    required this.clayLight,
    required this.onClayLight,
    required this.onAccent,
    required this.error,
    required this.onError,
  });

  final Brightness brightness;

  /// 正文与标题的颜色。
  final Color ink;

  /// 次要文字，例如说明与未选中的导航标签。
  final Color muted;

  /// 页面底色。
  final Color paper;

  /// 卡片、输入框与导航栏的底色。
  final Color card;

  /// 代码块底色。
  final Color code;

  /// 卡片与表格的描边。
  final Color border;

  /// 输入框未聚焦时的描边。
  final Color inputBorder;

  /// 主色，用在链接、选中状态与可操作的元素上。
  final Color moss;

  /// 主色的浅底，用在用户气泡、标签与导航指示块上。
  final Color mossLight;

  /// 主色的容器底色，用在选中芯片与次要按钮上。
  final Color mossContainer;

  /// 压在 [mossContainer] 上的文字颜色。
  final Color onMossContainer;

  /// 比页面底色高一档的表面，例如搜索栏与分段条。
  final Color raised;

  /// 次色，用在提醒与悬停状态上。
  final Color clay;

  /// 次色的浅底，用在草稿与优先这类需要留意的标签上。
  final Color clayLight;

  /// 压在 [clayLight] 上的文字颜色。
  final Color onClayLight;

  /// 压在主色上的文字或图标颜色。
  final Color onAccent;

  /// 错误与危险操作的颜色。
  final Color error;

  /// 压在错误色上的文字颜色。
  final Color onError;
}
