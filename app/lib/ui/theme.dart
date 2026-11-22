import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:forui/forui.dart' as forui;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';

import 'motion.dart';

export 'motion.dart';

/// 应用的两套外观：色值与字号只在这里定义一次，Forui 主题、页面读到的
/// 字号与颜色、回答正文的 Markdown 主题都从同一份生成。
///
/// 背景与表面不带色相：浅色是纯白与中性灰，深色是纯黑与中性灰，深浅两套的
/// 背景、卡片与描边都按灰阶给出。主题色只出现在主色、主色容器与提醒色上，
/// 用在按钮、链接、选中态、开关与强调卡片，不参与页面与卡片的底色。
///
/// 页面不再读 Material 的 `Theme.of`，统一读 Forui 主题里的 [ZhixinTheme]；
/// Material 的 `ThemeData` 只留给 `gpt_markdown`（它要 `GptMarkdownThemeData`
/// 与 `TextTheme`）和本地化，不再是一份需要单独维护的色板。
const _Palette _lightPalette = _Palette(
  brightness: Brightness.light,
  ink: Color(0xFF111111),
  muted: Color(0xFF6B6B72),
  paper: Color(0xFFFFFFFF),
  card: Color(0xFFFFFFFF),
  code: Color(0xFFF4F4F5),
  border: Color(0xFFE6E6E8),
  inputBorder: Color(0xFFC9C9CE),
  brand: Color(0xFF2563EB),
  brandLight: Color(0xFFEAF1FE),
  brandContainer: Color(0xFFD9E6FD),
  onBrandContainer: Color(0xFF12378A),
  raised: Color(0xFFF4F4F5),
  attention: Color(0xFFB45309),
  attentionLight: Color(0xFFFEF1DF),
  onAttentionLight: Color(0xFF7A3A06),
  onAccent: Color(0xFFFFFFFF),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
);

const _Palette _darkPalette = _Palette(
  brightness: Brightness.dark,
  ink: Color(0xFFECECEE),
  muted: Color(0xFF9D9DA5),
  paper: Color(0xFF000000),
  card: Color(0xFF131315),
  code: Color(0xFF0B0B0D),
  border: Color(0xFF2A2A2E),
  inputBorder: Color(0xFF45454B),
  brand: Color(0xFF5B9BFF),
  brandLight: Color(0xFF14243F),
  brandContainer: Color(0xFF1D3C6E),
  onBrandContainer: Color(0xFFD4E4FF),
  raised: Color(0xFF1E1E21),
  attention: Color(0xFFF0B070),
  attentionLight: Color(0xFF3A2A14),
  onAttentionLight: Color(0xFFFFDDB8),
  onAccent: Color(0xFF001A40),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
);

final forui.FThemeData zhixinForuiTheme = _buildForui(_lightPalette);
final forui.FThemeData zhixinDarkForuiTheme = _buildForui(_darkPalette);

/// 回答正文与 Material 本地化用的主题；页面不再从它取字号与颜色。
final ThemeData zhixinTheme = _buildMaterial(_lightPalette);
final ThemeData zhixinDarkTheme = _buildMaterial(_darkPalette);

/// 页面短提示的宿主样式：提示压在中下，底部为底栏导航留出高度。
///
/// Forui 默认把提示放在触屏设备的顶部，这里统一放到下面，屏幕上的提示位置
/// 不随平台改变。页面里的提示仍然只通过 `showToast` 与 `showActionToast` 打开。
final forui.FToasterStyleDelta zhixinToasterStyle =
    forui.FToasterStyleDelta.delta(
      toastAlignment: forui.FToastAlignment.bottomCenter,
      padding: forui.EdgeInsetsGeometryDelta.value(
        const EdgeInsets.fromLTRB(20, 15, 20, 96),
      ),
    );

const _controlRadius = Radius.circular(14);
const _cardRadius = Radius.circular(20);
const _featureRadius = Radius.circular(24);

/// 页面里的字号与颜色；从 Forui 主题的应用扩展读取。
extension ZhixinThemeContext on BuildContext {
  ZhixinTheme get zhixin => forui.FTheme.of(this).extension<ZhixinTheme>();
}

/// 页面与表单共用的字号、行高与字重。
class ZhixinTextStyles {
  const ZhixinTextStyles({
    required this.headlineMedium,
    required this.headlineSmall,
    required this.pageTitle,
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

  /// 一级页面标题栏的标题与关于页的应用名；首页的“知新”同用这一档。
  final TextStyle pageTitle;

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
    required this.primarySoft,
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

  /// 主色，用在按钮、链接、开关与选中状态上。
  final Color primary;

  /// 压在主色上的文字与图标，例如首页当前活动卡。
  final Color onPrimary;
  final Color onSurface;
  final Color error;
  final Color onError;

  /// 提醒色，与 [attention] 同值。
  final Color secondary;
  final Color onSurfaceVariant;

  /// 主色容器：选中芯片、用户气泡与输入区用它作底。
  final Color primaryContainer;

  /// 压在 [primaryContainer] 上的文字颜色。
  final Color onPrimaryContainer;

  /// 主色浅底：底栏指示块、标签底。
  final Color primarySoft;

  /// 容器描边：卡片、列表项、分隔线、底栏、对话框与面板；比 [outline] 浅。
  final Color outlineVariant;

  /// 控件描边：输入框、选择框、复选框与 outline 按钮；比 [outlineVariant] 深。
  final Color outline;

  /// 与 [primaryContainer] 同值；次要按钮的底色。
  final Color secondaryContainer;

  /// 与 [onPrimaryContainer] 同值。
  final Color onSecondaryContainer;
  final Color surface;

  /// 比页面底色高一档的中性表面，例如标签底、分段条与骨架块。
  final Color surfaceContainerHigh;
  final Color card;
}

/// 页面留白的几档取值；页面与公共组件只从这里取，不再各写一套数字。
class ZhixinSpace {
  const ZhixinSpace();

  /// 同一行里图标与文字、标签与标签之间。
  double get xs => 4;

  /// 同一张卡片里相邻两行之间；页面上竖直排列的两个条目（各自独立的卡片）之间也取这一档。
  double get sm => 8;

  /// 比 [sm] 小一点的间隔：历史记录、更正记录与步骤这类逐行排列的列表里相邻两行之间。
  /// 原来散在各页的 `sm - 2` 与 `xs + 2` 也归到这一档。
  double get tight => 6;

  /// 表单里相邻两行之间；和 [sm] 同值，单独一档方便以后调整。
  double get gap => 8;

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

  /// 一节标题上方的留白：比 [section] 少一档，接在上一节内容后面。
  double get sectionTop => 20;

  /// 内容区的最大宽度；平板与横屏上居中，不把一行拉得过长。
  double get maxWidth => 720;

  EdgeInsets pageInsets({double? top, double? bottom}) =>
      EdgeInsets.fromLTRB(page, top ?? md, page, bottom ?? section);
}

/// 标签、控件、列表卡片与强调卡片的圆角。
class ZhixinRadius {
  const ZhixinRadius();

  /// 标签与小按钮。
  BorderRadius get tag => const BorderRadius.all(Radius.circular(8));

  /// 按钮、输入框、分段控件与对话气泡。
  BorderRadius get control => const BorderRadius.all(_controlRadius);

  /// 列表与内容卡片。
  BorderRadius get card => const BorderRadius.all(_cardRadius);

  /// 首页当前活动与输入区这类一页只出现一次的卡片。
  BorderRadius get feature => const BorderRadius.all(_featureRadius);
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
  final colors = _foruiColors(base.colors, palette);
  final text = _textStyles(palette);
  final typography = base.typography.copyWith(
    display: _systemFace(base.typography.display).copyWith(
      xl2: text.headlineMedium,
      xl: text.titleLarge,
      lg: text.titleMedium,
      md: text.titleMedium,
    ),
    body: _systemFace(base.typography.body).copyWith(
      sm: text.bodyMedium,
      xs: text.bodyMedium,
      xs2: text.bodySmall,
      xs3: text.labelMedium,
    ),
  );
  final style = base.style.copyWith(
    borderRadius: base.style.borderRadius.copyWith(
      md: const BorderRadius.all(_controlRadius),
      lg: const BorderRadius.all(_cardRadius),
    ),
  );
  final scaffold = forui.FScaffoldStyle.inherit(colors: colors, style: style);
  final dialog = forui.FDialogStyle.inherit(
    colors: colors,
    typography: typography,
    style: style,
    hapticFeedback: base.hapticFeedback,
    touch: true,
  );
  return forui.FThemeData(
    colors: colors,
    typography: typography,
    style: style,
    cardStyle: forui.FCardStyle.inherit(
      colors: colors,
      style: style,
      typography: typography,
      touch: true,
    ),
    dialogStyle: dialog.copyWith(
      decoration: forui.DecorationDelta.shapeDelta(
        shape: RoundedSuperellipseBorder(
          borderRadius: const BorderRadius.all(_featureRadius),
          side: BorderSide(color: colors.border),
        ),
      ),
      titleTextStyle: forui.TextStyleDelta.value(
        text.titleLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      insetPadding: const .value(
        EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      ),
    ),
    scaffoldStyle: scaffold.copyWith(
      childPadding: const .value(EdgeInsets.zero),
      footerDecoration: const .value(BoxDecoration()),
    ),
    touch: true,
    extensions: [ZhixinTheme(text: text, colors: _colors(palette))],
  );
}

/// 以 Forui 的中性基底起步，把每一档颜色换成 [_Palette] 的取值。
///
/// 浅色下页面、卡片与列表都是同一片白，容器靠 [_Palette.border] 这一档浅
/// 描边分出层次；[_Palette.inputBorder] 更深，只给输入框、选择框、复选框与
/// outline 按钮这类交互控件用，见 [ZhixinColors.outline] 与
/// [ZhixinColors.outlineVariant]。深色下卡片比页面亮一档，[border] 同样
/// 能画出边界。
forui.FColors _foruiColors(forui.FColors base, _Palette palette) {
  return base.copyWith(
    background: palette.paper,
    foreground: palette.ink,
    primary: palette.brand,
    primaryForeground: palette.onAccent,
    secondary: palette.brandLight,
    secondaryForeground: palette.onBrandContainer,
    muted: palette.raised,
    mutedForeground: palette.muted,
    card: palette.card,
    border: palette.border,
    error: palette.error,
    errorForeground: palette.onError,
    destructive: palette.error,
    destructiveForeground: palette.onError,
  );
}

ZhixinTextStyles _textStyles(_Palette palette) {
  TextStyle style({
    required double fontSize,
    required double height,
    required double letterSpacing,
    FontWeight weight = FontWeight.w400,
  }) => TextStyle(
    // 不指定字族，中文与西文都跟随手机系统字体：指定自定义字族时，中文会
    // 回落到思源黑体，绕过厂商的系统字体，而且回退字重往往只有常规与粗体
    // 两档，w500、w600 会被就近取成粗体，整屏显得处处都粗。
    fontSize: fontSize,
    height: height,
    letterSpacing: letterSpacing,
    fontWeight: weight,
    color: palette.ink,
  );

  // 只有时间与计数用 Inter 的等宽数字，其余文字跟随系统字体。
  final figures =
      style(
        fontSize: 14,
        height: 1.3,
        letterSpacing: 0,
        weight: FontWeight.w600,
      ).copyWith(
        fontFamily: forui.FTypeface.defaultFontFamily,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  return ZhixinTextStyles(
    figures: figures,
    // 一屏一个的主标题，例如首页没有当前活动时的“提出一个问题”。
    headlineMedium: style(
      fontSize: 30,
      height: 1.26,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    headlineSmall: style(
      fontSize: 24,
      height: 1.33,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    pageTitle: style(
      fontSize: 26,
      height: 1.3,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    titleLarge: style(
      fontSize: 22,
      height: 1.27,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    titleMedium: style(
      fontSize: 16,
      height: 1.5,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    titleSmall: style(
      fontSize: 14,
      height: 1.43,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    bodyLarge: style(fontSize: 16, height: 1.55, letterSpacing: 0),
    bodyMedium: style(fontSize: 14, height: 1.5, letterSpacing: 0),
    bodySmall: style(fontSize: 12, height: 1.5, letterSpacing: 0),
    labelLarge: style(
      fontSize: 14,
      height: 1.43,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    labelMedium: style(
      fontSize: 12,
      height: 1.33,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
    labelSmall: style(
      fontSize: 11,
      height: 1.45,
      letterSpacing: 0,
      weight: FontWeight.w600,
    ),
  );
}

/// 把 Forui 的每一档文字换成系统字体：控件默认带 Inter 字族，逐档去掉字族
/// 之后，字号、行高、字重与颜色仍按 Forui 的取值，只有字形改由系统字体
/// 提供。`FTypeface` 的 `fontFamily` 字段要求非空，且只用于没有单独给出的
/// 档位；这里每一档都给出了样式，字段本身不参与渲染。
forui.FTypeface _systemFace(forui.FTypeface base) => base.copyWith(
  xs3: _systemText(base.xs3),
  xs2: _systemText(base.xs2),
  xs: _systemText(base.xs),
  sm: _systemText(base.sm),
  md: _systemText(base.md),
  lg: _systemText(base.lg),
  xl: _systemText(base.xl),
  xl2: _systemText(base.xl2),
  xl3: _systemText(base.xl3),
  xl4: _systemText(base.xl4),
  xl5: _systemText(base.xl5),
  xl6: _systemText(base.xl6),
  xl7: _systemText(base.xl7),
  xl8: _systemText(base.xl8),
);

/// 复制一份不带字族的文字样式；[TextStyle.copyWith] 无法清空字族，只能重建。
TextStyle _systemText(TextStyle style) => TextStyle(
  color: style.color,
  foreground: style.foreground,
  backgroundColor: style.backgroundColor,
  fontSize: style.fontSize,
  fontWeight: style.fontWeight,
  fontStyle: style.fontStyle,
  letterSpacing: style.letterSpacing,
  wordSpacing: style.wordSpacing,
  textBaseline: style.textBaseline,
  height: style.height,
  leadingDistribution: style.leadingDistribution,
  locale: style.locale,
  decoration: style.decoration,
  decorationColor: style.decorationColor,
  decorationStyle: style.decorationStyle,
  decorationThickness: style.decorationThickness,
  fontFeatures: style.fontFeatures,
  fontVariations: style.fontVariations,
  shadows: style.shadows,
  background: style.background,
);

ZhixinColors _colors(_Palette palette) => ZhixinColors(
  primary: palette.brand,
  onPrimary: palette.onAccent,
  onSurface: palette.ink,
  error: palette.error,
  onError: palette.onError,
  secondary: palette.attention,
  onSurfaceVariant: palette.muted,
  outline: palette.inputBorder,
  outlineVariant: palette.border,
  primaryContainer: palette.brandContainer,
  onPrimaryContainer: palette.onBrandContainer,
  primarySoft: palette.brandLight,
  secondaryContainer: palette.brandContainer,
  onSecondaryContainer: palette.onBrandContainer,
  surface: palette.paper,
  surfaceContainerHigh: palette.raised,
  card: palette.card,
  attention: palette.attention,
  attentionContainer: palette.attentionLight,
  onAttentionContainer: palette.onAttentionLight,
);

/// gpt_markdown 仍按 Material 的 `ThemeData` 取样式与 `GptMarkdownThemeData`，
/// 这里用它需要的那部分，色值与字号同样来自 [_Palette] 与 [_textStyles]。
///
/// 色板直接由 [_Palette] 构造，不用 `ColorScheme.fromSeed`：从主色取种子时，
/// 没写出来的表面、容器与色调角色都会按主色的色相染色，背景与卡片就不再是
/// 中性灰。这里把所有会画到底色上的角色一次写全，`surfaceTint` 取透明，
/// 叠加色调不会再把底色染蓝。
ThemeData _buildMaterial(_Palette palette) {
  final colors = ColorScheme(
    brightness: palette.brightness,
    primary: palette.brand,
    onPrimary: palette.onAccent,
    primaryContainer: palette.brandContainer,
    onPrimaryContainer: palette.onBrandContainer,
    primaryFixed: palette.brandLight,
    primaryFixedDim: palette.brandContainer,
    onPrimaryFixed: palette.onBrandContainer,
    onPrimaryFixedVariant: palette.onBrandContainer,
    secondary: palette.attention,
    onSecondary: palette.onAttentionLight,
    secondaryContainer: palette.brandContainer,
    onSecondaryContainer: palette.onBrandContainer,
    tertiary: palette.attention,
    onTertiary: palette.onAttentionLight,
    surface: palette.paper,
    onSurface: palette.ink,
    onSurfaceVariant: palette.muted,
    surfaceDim: palette.raised,
    surfaceBright: palette.card,
    surfaceContainerLowest: palette.code,
    surfaceContainerLow: palette.raised,
    surfaceContainer: palette.card,
    surfaceContainerHigh: palette.raised,
    surfaceContainerHighest: palette.raised,
    inverseSurface: palette.ink,
    onInverseSurface: palette.paper,
    inversePrimary: palette.brandLight,
    outline: palette.inputBorder,
    outlineVariant: palette.border,
    error: palette.error,
    onError: palette.onError,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(
    colorScheme: colors,
    scaffoldBackgroundColor: palette.paper,
    dividerColor: palette.border,
  );
  final text = _textStyles(palette);
  return base.copyWith(
    // 页面路由的过渡在这里配一次，各页不再各写一套：安卓交给系统的预测性
    // 返回，手势中显示返回预览；iOS 与 macOS 保留 Cupertino 的滑回手势；
    // 桌面没有返回手势，用淡入加右推。减少动态效果时由 builder 直接给终态。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: ZhixinAndroidPageTransitionsBuilder(),
        TargetPlatform.fuchsia: ZhixinPageTransitionsBuilder(),
        TargetPlatform.linux: ZhixinPageTransitionsBuilder(),
        TargetPlatform.windows: ZhixinPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.paper,
      foregroundColor: palette.ink,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.brand,
      refreshBackgroundColor: palette.card,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: palette.card,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(_featureRadius),
      ),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(_featureRadius),
      ),
    ),
    // 底部面板改用 Material 之后，底色、上圆角与拖动条从这里取；页面打开
    // 面板时只写 showDragHandle 等行为，不再各配一遍样式。
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.card,
      modalBackgroundColor: palette.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      dragHandleColor: palette.inputBorder,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: _featureRadius),
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
    // 级别，链接用主色、悬停用提醒色，不再落到组件默认的颜色。
    extensions: <ThemeExtension<dynamic>>[
      GptMarkdownThemeData(
        brightness: palette.brightness,
        linkColor: palette.brand,
        linkHoverColor: palette.attention,
        // 聊天里的 h1 不画文档式分隔线。
        autoAddDividerLineAfterH1: false,
        h1: text.titleLarge.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
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
            headerBackground: palette.brandLight,
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
            barColor: palette.brand,
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
///
/// 底色与表面的几档（[paper]、[card]、[raised]、[code]、[border]、
/// [inputBorder]、[ink]、[muted]）不带色相；带色相的只有主色 [brand] 一族、
/// 提醒色 [attention] 一族与错误色，它们只用在按钮、链接、选中态与状态标签上。
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
    required this.brand,
    required this.brandLight,
    required this.brandContainer,
    required this.onBrandContainer,
    required this.raised,
    required this.attention,
    required this.attentionLight,
    required this.onAttentionLight,
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
  final Color brand;

  /// 主色的浅底，用在用户气泡、标签与导航指示块上。
  final Color brandLight;

  /// 主色的容器底色，用在选中芯片与次要按钮上。
  final Color brandContainer;

  /// 压在 [brandContainer] 上的文字颜色。
  final Color onBrandContainer;

  /// 比页面底色高一档的表面，例如搜索栏与分段条。
  final Color raised;

  /// 提醒色，用在需要留意的状态与链接的悬停上。
  final Color attention;

  /// 提醒色的浅底，用在草稿与优先这类需要留意的标签上。
  final Color attentionLight;

  /// 压在 [attentionLight] 上的文字颜色。
  final Color onAttentionLight;

  /// 压在主色上的文字或图标颜色。
  final Color onAccent;

  /// 错误与危险操作的颜色。
  final Color error;

  /// 压在错误色上的文字颜色。
  final Color onError;
}
