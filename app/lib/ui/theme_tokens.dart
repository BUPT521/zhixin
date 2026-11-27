part of 'theme.dart';

/// 不随主题色改变的底色、表面、描边、文字与错误色，深浅两套各一份。
///
/// 这几档都按灰阶给出，三通道相差不超过两档，肉眼分不出色相；换主题色时
/// 它们不变，页面与卡片因此始终是纯白或纯黑。
class _NeutralPalette {
  const _NeutralPalette({
    required this.brightness,
    required this.ink,
    required this.muted,
    required this.paper,
    required this.card,
    required this.code,
    required this.border,
    required this.inputBorder,
    required this.raised,
    required this.selectedSurface,
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

  /// 比页面底色高一档的表面，例如搜索栏与分段条。
  final Color raised;

  /// 分段控件选中项的底色；浅色下是纯白，深色下比 [raised] 再亮一档。
  final Color selectedSurface;

  /// 错误与危险操作的颜色。
  final Color error;

  /// 压在错误色上的文字颜色。
  final Color onError;
}

const _NeutralPalette _lightNeutral = _NeutralPalette(
  brightness: Brightness.light,
  ink: Color(0xFF111111),
  muted: Color(0xFF6B6B72),
  paper: Color(0xFFFFFFFF),
  card: Color(0xFFFFFFFF),
  code: Color(0xFFF4F4F5),
  border: Color(0xFFE6E6E8),
  inputBorder: Color(0xFFC9C9CE),
  raised: Color(0xFFF4F4F5),
  selectedSurface: Color(0xFFFFFFFF),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
);

const _NeutralPalette _darkNeutral = _NeutralPalette(
  brightness: Brightness.dark,
  ink: Color(0xFFECECEE),
  muted: Color(0xFF9D9DA5),
  paper: Color(0xFF000000),
  card: Color(0xFF131315),
  code: Color(0xFF0B0B0D),
  border: Color(0xFF2A2A2E),
  inputBorder: Color(0xFF45454B),
  raised: Color(0xFF1E1E21),
  selectedSurface: Color(0xFF2F2F2F),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
);

_NeutralPalette _neutral(Brightness brightness) =>
    brightness == Brightness.light ? _lightNeutral : _darkNeutral;

/// 可选的六个主题色。每个值只有主色的浅色与深色两个取值，主色家族与提醒色
/// 都由 [_palette] 按这两个取值派生，页面不各自判断。
enum ZhixinAccent {
  blue('蓝', Color(0xFF2563EB), Color(0xFF5B9BFF)),
  moss('苔绿', Color(0xFF245C48), Color(0xFF6FCF97)),
  violet('紫', Color(0xFF7C3AED), Color(0xFFA78BFA)),
  rose('玫红', Color(0xFFBE185D), Color(0xFFF472B6)),
  orange('橙', Color(0xFFC2410C), Color(0xFFFB923C)),
  graphite('石墨', Color(0xFF18181B), Color(0xFFE4E4E7));

  const ZhixinAccent(this.label, this.light, this.dark);

  /// 设置页色块的无障碍标签与说明里用的名称。
  final String label;

  /// 浅色外观的主色。
  final Color light;

  /// 深色外观的主色。
  final Color dark;

  /// 读取保存的主题色名称；空值与不认识的名称都回到默认的蓝色。
  static ZhixinAccent parse(String? stored) {
    for (final accent in values) {
      if (accent.name == stored) return accent;
    }
    return blue;
  }

  /// 深浅两套外观都要用的色值，对外只按亮度给出。
  Color primaryFor(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;

  /// 这个主题色是石墨这类无彩色时，主色家族直接取中性灰。
  bool get _achromatic => this == graphite;
}

const ZhixinAccent kDefaultAccent = ZhixinAccent.blue;

const _tagRadius = Radius.circular(6);
const _controlRadius = Radius.circular(12);
const _cardRadius = Radius.circular(16);
const _featureRadius = Radius.circular(20);

/// 12 与 16 两档的常量形式：控件内边距这类 `const` 样式要在编译期取到它们，
/// 与 [ZhixinSpace] 的 getter 共用同一个取值，数字只写在这里。
const double _mdValue = 12;
const double _lgValue = 16;

/// 列表项、入口卡片与空态内容区共用的横向内边距，与卡片内边距 [ZhixinSpace.lg]
/// 同取 [_lgValue]；几种卡片里文字的起始位置因此一致，同等宽度的卡片换一种也
/// 读不到跳变。
const double kCardInset = _lgValue;

/// 控件内容与描边之间的横向留白；按钮、输入框与选择框同取这一档，与
/// [ZhixinSpace.md] 同取 [_mdValue]，并排时文字到框边的距离一样。
const double _controlPadH = _mdValue;

/// 带图标的按钮里图标与标签之间的间隔。
const double _controlGap = 6;

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

  /// 时刻、时长与计数用的等宽数字。
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
    required this.surfaceSelected,
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

  /// 分段控件选中项的底色；深浅两套都比分段条亮一档，切换时不会出现一块更暗的
  /// 底压在轨道上。
  final Color surfaceSelected;

  final Color card;
}

/// 页面留白的几档取值；页面与公共组件只从这里取，不再各写一套数字。
class ZhixinSpace {
  const ZhixinSpace();

  /// 按钮、输入框与选择框的内容区高度：三者同高，排在同一行时上下对齐。
  static const double controlHeight = 44;

  /// 页面左右边距的常量形式；主题之外的地方（底栏与标题栏的样式）也取这一档。
  /// [page] 与它是同一个取值。
  static const double pageInset = 24;

  /// 同一行里图标与文字、标签与标签之间。
  double get xs => 4;

  /// 同一张卡片里相邻两行之间；页面上竖直排列的两个条目（各自独立的卡片）之间也取这一档。
  double get sm => 8;

  /// 比 [sm] 小一点的间隔：历史记录、更正记录与步骤这类逐行排列的列表里相邻两行之间。
  /// 原来散在各页的 `sm - 2` 与 `xs + 2` 也归到这一档。
  double get tight => 6;

  /// 表单里相邻两行之间；和 [sm] 同值，单独一档方便以后调整。
  double get gap => 8;

  /// 列表里相邻两张卡片之间、卡片内边距的短边；与 [_mdValue] 同值。
  double get md => _mdValue;

  /// 卡片内边距；与 [_lgValue] 同值，列表项的横向内边距 [kCardInset] 也取这一档。
  double get lg => _lgValue;

  /// 页面左右边距；标题栏、分段条、卡片与底栏都取这一档，内容区的两侧
  /// 因此在整屏上下对齐。标题栏里的图标按可点区域居中，图标离屏边 [page] + 6。
  double get page => pageInset;

  /// 空态与对话框这类需要松一些的内边距。
  double get xl => 24;

  /// 相邻两节之间。
  double get section => 28;

  /// 一节标题上方的留白：比 [section] 少一档，接在上一节内容后面。
  double get sectionTop => 24;

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
      fontSize: 20,
      height: 1.3,
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
  surfaceSelected: palette.selectedSurface,
  card: palette.card,
  attention: palette.attention,
  attentionContainer: palette.attentionLight,
  onAttentionContainer: palette.onAttentionLight,
);

/// 一个主题色在某个亮度下的派生结果：色板、页面颜色与字号。
///
/// Forui 主题与 Material 主题从同一份取用，两套主题构建时不再各自把色板、
/// [_colors] 与 [_textStyles] 再算一遍。
typedef _Tokens = ({
  _Palette palette,
  ZhixinColors colors,
  ZhixinTextStyles text,
});

final Map<(ZhixinAccent, Brightness), _Tokens> _tokenCache = {};

_Tokens _tokensFor(ZhixinAccent accent, Brightness brightness) =>
    _tokenCache.putIfAbsent((accent, brightness), () {
      final palette = _palette(_neutral(brightness), accent);
      return (
        palette: palette,
        colors: _colors(palette),
        text: _textStyles(palette),
      );
    });
