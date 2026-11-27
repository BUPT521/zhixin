import 'dart:math' as math;

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
/// 色板分成两部分：背景、表面、描边、文字与错误色是固定的中性色，深浅两套
/// 各一份，不随主题色改变；主色家族（主色、压在主色上的文字、主色浅底、
/// 主色容器与容器上的文字）与提醒色由 [ZhixinAccent] 生成，见 [_palette]。
/// 所以换主题色时只有按钮、链接、选中态与强调卡片的颜色变，页面与卡片的
/// 底色始终是纯白或纯黑，不带主题色的色相。
///
/// 页面不再读 Material 的 `Theme.of`，统一读 Forui 主题里的 [ZhixinTheme]；
/// Material 的 `ThemeData` 只留给 `gpt_markdown`（它要 `GptMarkdownThemeData`
/// 与 `TextTheme`）和本地化，不再是一份需要单独维护的色板。
///
/// 六个主题色的浅色与深色两套主题由 [foruiThemesFor] 与 [materialThemesFor]
/// 生成；[zhixinForuiTheme] 与 [zhixinTheme] 是默认蓝色主题，[zhixinDarkForuiTheme]
/// 与 [zhixinDarkTheme] 是它的深色一套。
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

forui.FThemeData _buildForui(ZhixinAccent accent, Brightness brightness) =>
    _foruiTheme(_palette(_neutral(brightness), accent));

ThemeData _buildMaterial(ZhixinAccent accent, Brightness brightness) =>
    _materialTheme(_palette(_neutral(brightness), accent));

/// 某个主题色在某个亮度下所有主题色主题的缓存：换过一次之后再回来直接取，
/// 切换与启动都不必重算。
final Map<String, forui.FThemeData> _foruiThemes = {};
final Map<String, ThemeData> _materialThemes = {};

String _themeKey(ZhixinAccent accent, Brightness brightness) =>
    '${accent.name}-${brightness.name}';

forui.FThemeData _cachedForui(ZhixinAccent accent, Brightness brightness) =>
    _foruiThemes.putIfAbsent(
      _themeKey(accent, brightness),
      () => _buildForui(accent, brightness),
    );

ThemeData _cachedMaterial(ZhixinAccent accent, Brightness brightness) =>
    _materialThemes.putIfAbsent(
      _themeKey(accent, brightness),
      () => _buildMaterial(accent, brightness),
    );

/// 某个主题色的两套 Forui 主题：应用根部把浅色与深色分别交给 Material 与
/// Forui，主题色一换就换成这一份。
Map<Brightness, forui.FThemeData> foruiThemesFor(ZhixinAccent accent) => {
  Brightness.light: _cachedForui(accent, Brightness.light),
  Brightness.dark: _cachedForui(accent, Brightness.dark),
};

/// 某个主题色的两套 Material 主题。
Map<Brightness, ThemeData> materialThemesFor(ZhixinAccent accent) => {
  Brightness.light: _cachedMaterial(accent, Brightness.light),
  Brightness.dark: _cachedMaterial(accent, Brightness.dark),
};

/// 默认蓝色主题的两套 Forui 主题。
final forui.FThemeData zhixinForuiTheme = _cachedForui(
  kDefaultAccent,
  Brightness.light,
);
final forui.FThemeData zhixinDarkForuiTheme = _cachedForui(
  kDefaultAccent,
  Brightness.dark,
);

/// 回答正文与 Material 本地化用的主题；页面不再从它取字号与颜色。
final ThemeData zhixinTheme = _cachedMaterial(kDefaultAccent, Brightness.light);
final ThemeData zhixinDarkTheme = _cachedMaterial(
  kDefaultAccent,
  Brightness.dark,
);

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

const _tagRadius = Radius.circular(6);
const _controlRadius = Radius.circular(12);
const _cardRadius = Radius.circular(16);
const _featureRadius = Radius.circular(20);

/// 列表项、入口卡片与空态内容区共用的横向内边距，与卡片内边距 [ZhixinSpace.lg]
/// 同值；几种卡片里文字的起始位置因此一致，同等宽度的卡片换一种也读不到跳变。
const double kCardInset = 16;

/// 控件内容与描边之间的横向留白；按钮、输入框与选择框同取这一档，并排时文字
/// 到框边的距离一样。
const double _controlPadH = 12;

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
  /// 改 [page] 时两处要一起改。
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

  /// 列表里相邻两张卡片之间、卡片内边距的短边。
  double get md => 12;

  /// 卡片内边距。
  double get lg => 16;

  /// 页面左右边距；标题栏、分段条、卡片与底栏都取这一档，内容区的两侧
  /// 因此在整屏上下对齐。标题栏里的图标按可点区域居中，图标离屏边 [page] + 6。
  double get page => 24;

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

forui.FThemeData _foruiTheme(_Palette palette) {
  final base = palette.brightness == Brightness.light
      ? forui.FTheme.neutral.light.touch
      : forui.FTheme.neutral.dark.touch;
  final colors = _foruiColors(base.colors, palette);
  final zhixin = _colors(palette);
  final icons = base.icons;
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
      xs2: const BorderRadius.all(_tagRadius),
      sm: const BorderRadius.all(_tagRadius),
      md: const BorderRadius.all(_controlRadius),
      lg: const BorderRadius.all(_cardRadius),
    ),
    // 表单标签取 labelLarge，说明与错误文字取 bodySmall，色值跟着色板走。
    formFieldStyle: forui.FFormFieldStyle(
      labelTextStyle: forui.FVariants.all(
        text.labelLarge.copyWith(color: colors.foreground),
      ),
      descriptionTextStyle: forui.FVariants.all(
        text.bodySmall.copyWith(color: colors.mutedForeground),
      ),
      errorTextStyle: forui.FVariants.all(
        text.bodySmall.copyWith(color: colors.error),
      ),
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
    cardStyle:
        forui.FCardStyle.inherit(
          colors: colors,
          style: style,
          typography: typography,
          touch: true,
        ).copyWith(
          titleTextStyle: forui.TextStyleDelta.value(text.titleMedium),
          subtitleTextStyle: forui.TextStyleDelta.value(text.bodySmall),
        ),
    buttonStyles: _buttonStyles(colors, typography, style, text),
    textFieldStyles: _textFieldStyles(colors, zhixin, style, text),
    selectStyle: _selectStyle(colors, zhixin, icons, typography, style, text),
    tileStyles: _tileStyles(colors, style, text),
    tileGroupStyle: base.tileGroupStyle.copyWith(
      dividerColor: forui.FVariants.all(colors.border),
      tileStyles: .delta([.all(_tilePressFeedback(colors.muted))]),
    ),
    switchStyle: _switchStyle(colors, style),
    accordionStyle: _accordionStyle(colors, style, text),
    bottomNavigationBarStyle: _navigationBarStyle(
      colors,
      typography,
      style,
      text,
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

// 手指刚落下时先显示底色，前 56 毫秒保持原尺寸，给列表滚动留出识别时间。
// Forui 只缩放绘制内容，大卡片最长边最多缩小 4 个逻辑像素。
const _pressFeedback = forui.FTappableStyleDelta.delta(
  pressedEnterDuration: Duration.zero,
  pressedExitDuration: Duration(milliseconds: 60),
  motion: forui.FTappableMotion(
    bounceDownDuration: Duration(milliseconds: 140),
    bounceUpDuration: Duration(milliseconds: 110),
    bounceDownCurve: Interval(0.4, 1, curve: Curves.easeOutCubic),
    bounceFloor: 4,
  ),
);

/// Forui 按钮的默认样式：圆角与其它控件同为 [ZhixinRadius.control]；标签只用
/// 强调字重，`sm` 标签 12.5、其余尺寸取 `labelLarge` 的 14。带图标的按钮里图标
/// 与标签之间的间隔按正文档收窄，内容高度不变；`sm` 的横向内边距 14、纵向 8。
/// ghost 是文字按钮，图标与文字都用主色。内容区的最小尺寸沿用 Forui 触摸布局
/// 的取值，可点区域不缩小。
forui.FButtonStyles _buttonStyles(
  forui.FColors colors,
  forui.FTypography typography,
  forui.FStyle style,
  ZhixinTextStyles text,
) {
  final base = forui.FButtonStyles.inherit(
    colors: colors,
    typography: typography,
    style: style,
    touch: true,
  );

  forui.FButtonStyle resized(
    forui.FButtonStyle button, {
    required bool small,
    Color? color,
  }) {
    final content = button.contentStyle;
    return button.copyWith(
      tappableStyle: _pressFeedback(button.tappableStyle),
      contentStyle: content.copyWith(
        textStyle: forui.FVariants.all(
          content.textStyle.base.copyWith(
            fontSize: small ? 12.5 : 14,
            fontWeight: text.labelLarge.fontWeight,
            color: color ?? content.textStyle.base.color,
          ),
        ),
        iconStyle: color == null
            ? null
            : forui.FVariants.all(
                content.iconStyle.base.copyWith(color: color),
              ),
        // 按钮与输入框统一 [ZhixinSpace.controlHeight]：内容区最小高度按同一档
        // 给，内边距与标签再在它里面居中。横向留白与输入框同取 [_controlPadH]，
        // 并排时文字离框边一样远。
        constraints: const BoxConstraints(
          minWidth: ZhixinSpace.controlHeight,
          minHeight: ZhixinSpace.controlHeight,
        ),
        spacing: _controlGap,
        padding: small
            ? const .value(EdgeInsets.symmetric(horizontal: 14, vertical: 8))
            : const .value(
                EdgeInsets.symmetric(horizontal: _controlPadH, vertical: 12),
              ),
      ),
    );
  }

  forui.FButtonSizeStyles sizes(
    forui.FButtonSizeStyles sizes, {
    Color? color,
  }) => forui.FButtonSizeStyles(
    forui.FVariants(
      resized(sizes.md, small: false, color: color),
      variants: {
        [forui.FButtonSizeVariant.xs]: resized(
          sizes.xs,
          small: false,
          color: color,
        ),
        [forui.FButtonSizeVariant.sm]: resized(
          sizes.sm,
          small: true,
          color: color,
        ),
        [forui.FButtonSizeVariant.lg]: resized(
          sizes.lg,
          small: false,
          color: color,
        ),
      },
    ),
  );

  // 空心按钮与文字按钮按下时只压出一层中性表面：Forui 默认取次要按钮的浅底，
  // 深色外观下那是一块暗蓝，按一下像闪了一下黑。选中态与按下态用同一档底色，
  // 悬停与键盘聚焦也不另画颜色。
  forui.FButtonSizeStyles outlineSizes() => forui.FButtonSizeStyles.inherit(
    typography: typography,
    style: style,
    touch: true,
    decoration: (radius) => .from(
      ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          side: BorderSide(color: colors.border, width: style.borderWidth),
          borderRadius: radius,
        ),
        color: colors.card,
      ),
      variants: {
        [.hovered, .pressed]: .shapeDelta(color: colors.muted),
        [.disabled]: .shapeDelta(color: colors.disable(colors.card)),
        [.selected]: .shapeDelta(color: colors.muted),
        [.selected.and(.disabled)]: .shapeDelta(
          color: colors.disable(colors.muted),
        ),
      },
    ),
    foregroundColor: colors.secondaryForeground,
    disabledForegroundColor: colors.disable(colors.secondaryForeground),
  );

  forui.FButtonSizeStyles ghostSizes() => forui.FButtonSizeStyles.inherit(
    typography: typography,
    style: style,
    touch: true,
    decoration: (radius) => .from(
      ShapeDecoration(shape: RoundedSuperellipseBorder(borderRadius: radius)),
      variants: {
        [.hovered, .pressed]: .shapeDelta(color: colors.muted),
        [.disabled]: const .shapeDelta(),
        [.selected]: .shapeDelta(color: colors.muted),
        [.selected.and(.disabled)]: .shapeDelta(
          color: colors.disable(colors.muted),
        ),
      },
    ),
    foregroundColor: colors.secondaryForeground,
    disabledForegroundColor: colors.disable(colors.secondaryForeground),
  );

  return forui.FButtonStyles(
    forui.FVariants(
      sizes(base.primary),
      variants: {
        [forui.FButtonVariant.primary]: sizes(base.primary),
        [forui.FButtonVariant.secondary]: sizes(base.secondary),
        [forui.FButtonVariant.destructive]: sizes(base.destructive),
        [forui.FButtonVariant.outline]: sizes(outlineSizes()),
        [forui.FButtonVariant.ghost]: sizes(
          ghostSizes(),
          color: colors.primary,
        ),
      },
    ),
  );
}

/// Forui 输入框的默认样式：圆角 [ZhixinRadius.control]，未聚焦的边用控件描边
/// [ZhixinColors.outline]、聚焦的边用主色；输入与占位用 `bodyMedium`，计数用
/// `bodySmall`。选择框复用这一份尺寸样式。
forui.FTextFieldSizeStyles _textFieldStyles(
  forui.FColors colors,
  ZhixinColors zhixin,
  forui.FStyle style,
  ZhixinTextStyles text,
) {
  final base = forui.FTextFieldSizeStyles.inherit(
    colors: colors,
    typography: forui.FTypography(
      display: forui.FTypeface(),
      body: forui.FTypeface(),
    ),
    style: style,
    touch: true,
  );
  final radius = style.borderRadius.md;

  InputBorder border(Color color) => OutlineInputBorder(
    borderSide: BorderSide(color: color, width: style.borderWidth),
    borderRadius: radius,
  );

  forui.FTextFieldStyle fixed(forui.FTextFieldStyle field) => field.copyWith(
    // 输入框与按钮同高，三种尺寸都取这一档；内边距与文字仍在它里面居中。
    constraints: const BoxConstraints(minHeight: ZhixinSpace.controlHeight),
    border: forui.FVariants(
      border(zhixin.outline),
      variants: {
        [forui.FTextFieldVariant.focused]: border(colors.primary),
        [forui.FTextFieldVariant.error]: border(colors.error),
        [forui.FTextFieldVariant.disabled]: border(
          colors.disable(zhixin.outline),
        ),
      },
    ),
    contentTextStyle: forui.FVariants.all(
      text.bodyMedium.copyWith(color: colors.foreground),
    ),
    hintTextStyle: forui.FVariants.all(
      text.bodyMedium.copyWith(color: colors.mutedForeground),
    ),
    counterTextStyle: forui.FVariants.all(
      text.bodySmall.copyWith(color: colors.mutedForeground),
    ),
  );

  return forui.FTextFieldSizeStyles(
    forui.FVariants(
      fixed(base.md),
      variants: {
        [forui.FTextFieldSizeVariant.sm]: fixed(base.sm),
        [forui.FTextFieldSizeVariant.lg]: fixed(base.lg),
      },
    ),
  );
}

/// Forui 选择框：字段部分与输入框同一样式。
forui.FSelectStyle _selectStyle(
  forui.FColors colors,
  ZhixinColors zhixin,
  forui.FIcons icons,
  forui.FTypography typography,
  forui.FStyle style,
  ZhixinTextStyles text,
) {
  final base = forui.FSelectStyle.inherit(
    colors: colors,
    typography: typography,
    icons: icons,
    style: style,
    touch: true,
  );
  return forui.FSelectStyle(
    fieldStyles: _textFieldStyles(colors, zhixin, style, text),
    searchStyle: base.searchStyle,
    contentStyle: base.contentStyle,
    emptyTextStyle: base.emptyTextStyle,
  );
}

/// Forui 列表项的默认样式：圆角 [ZhixinRadius.card]，容器描边
/// [ZhixinColors.outlineVariant]，标题 `titleSmall`，副标题 `bodySmall` 加次要
/// 文字色，右侧箭头 16 用次要文字色；内边距横向 [kCardInset]、纵向 `space.md`。
forui.FTileStyles _tileStyles(
  forui.FColors colors,
  forui.FStyle style,
  ZhixinTextStyles text,
) {
  const space = ZhixinSpace();
  final base = forui.FTileStyles.inherit(
    colors: colors,
    typography: forui.FTypography(
      display: forui.FTypeface(),
      body: forui.FTypeface(),
    ),
    style: style,
  );
  final padding = EdgeInsets.symmetric(
    horizontal: kCardInset,
    vertical: space.md,
  );

  final pressFeedback = _tilePressFeedback(colors.muted);
  forui.FTileStyle fixed(forui.FTileStyle tile) => pressFeedback(tile).copyWith(
    contentStyle: tile.contentStyle.copyWith(
      titleTextStyle: forui.FVariants.all(
        text.titleSmall.copyWith(color: colors.foreground),
      ),
      subtitleTextStyle: forui.FVariants.all(
        text.bodySmall.copyWith(color: colors.mutedForeground),
      ),
      detailsTextStyle: forui.FVariants.all(
        text.bodySmall.copyWith(color: colors.mutedForeground),
      ),
      suffixIconStyle: forui.FVariants.all(
        IconThemeData(color: colors.mutedForeground, size: 16),
      ),
      suffixedPadding: forui.EdgeInsetsGeometryDelta.value(
        EdgeInsets.fromLTRB(kCardInset, space.md, space.md, space.md),
      ),
      unsuffixedPadding: forui.EdgeInsetsGeometryDelta.value(padding),
    ),
    rawContentStyle: tile.rawContentStyle.copyWith(
      childTextStyle: forui.FVariants.all(text.titleSmall),
      padding: forui.EdgeInsetsGeometryDelta.value(padding),
    ),
  );

  return forui.FTileStyles(
    forui.FVariants(
      fixed(base.primary),
      variants: {
        [forui.FItemVariant.destructive]: fixed(base.destructive),
      },
    ),
  );
}

/// 可点卡片沿用空心按钮的中性按下底色，两个组件都通过平面与描边区分边界。
forui.FTileStyleDelta _tilePressFeedback(Color background) => .delta(
  contentDecoration: .delta([
    .exact({.hovered, .pressed}, .shapeDelta(color: background)),
  ]),
  tappableStyle: _pressFeedback,
);

/// Forui 开关：开启时轨道取主色，关闭时取容器描边那一档，圆钮取页面底色；
/// 两边的文字沿用 Forui 的标签样式。
///
/// 关闭态的轨道不取页面底色：浅色下页面与卡片都是纯白，轨道会与卡片并成
/// 一片，只看得到一个悬空的圆钮；改用描边色之后深浅两套外观都能看出轨道。
forui.FSwitchStyle _switchStyle(forui.FColors colors, forui.FStyle style) {
  final base = forui.FSwitchStyle.inherit(colors: colors, style: style);
  return base.copyWith(
    trackColor: forui.FVariants(
      colors.border,
      variants: {
        [forui.FSwitchVariant.selected]: colors.primary,
        [forui.FSwitchVariant.disabled]: colors.disable(colors.border),
        [forui.FSwitchVariant.selected.and(forui.FSwitchVariant.disabled)]:
            colors.disable(colors.primary),
      },
    ),
  );
}

/// 底栏：不靠字重与胶囊区分选中，只改颜色：选中为主色，其余为次要文字色。
/// 容器描边由 Forui 的 border 给出，与卡片、列表项同一档。
forui.FBottomNavigationBarStyle _navigationBarStyle(
  forui.FColors colors,
  forui.FTypography typography,
  forui.FStyle style,
  ZhixinTextStyles text,
) {
  final base = forui.FBottomNavigationBarStyle.inherit(
    colors: colors,
    typography: typography,
    style: style,
  );
  return forui.FBottomNavigationBarStyle(
    decoration: base.decoration,
    itemStyle: forui.FBottomNavigationBarItemStyle(
      // 图标颜色由页面按当前栏给（选中的是正文色、其余是次要文字色），这里只定文字。
      iconStyle: forui.FVariants.all(
        IconThemeData(color: colors.mutedForeground),
      ),
      textStyle: forui.FVariants(
        text.labelSmall.copyWith(color: colors.mutedForeground),
        variants: {
          [forui.FTappableVariant.selected]: text.labelSmall.copyWith(
            color: colors.primary,
          ),
        },
      ),
      tappableStyle: style.tappableStyle,
      focusedOutlineStyle: style.focusedOutlineStyle,
      padding: const EdgeInsets.all(5),
      spacing: 4,
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: ZhixinSpace.pageInset,
      vertical: 4,
    ),
  );
}

/// Forui 折叠面板：标题 `labelLarge` 加强调字重，正文 `bodyMedium`。
forui.FAccordionStyle _accordionStyle(
  forui.FColors colors,
  forui.FStyle style,
  ZhixinTextStyles text,
) {
  final base = forui.FAccordionStyle.inherit(
    colors: colors,
    typography: forui.FTypography(
      display: forui.FTypeface(),
      body: forui.FTypeface(),
    ),
    style: style,
    touch: true,
  );
  return base.copyWith(
    titleTextStyle: forui.FVariants.all(text.labelLarge),
    childTextStyle: forui.TextStyleDelta.value(text.bodyMedium),
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
  surfaceSelected: palette.selectedSurface,
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
ThemeData _materialTheme(_Palette palette) {
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

/// 一套完整的外观：中性色板，加上由主题色生成的主色家族与提醒色。
///
/// 带色相的只有主色 [brand] 一族与提醒色 [attention] 一族，它们只用在按钮、
/// 链接、选中态与状态标签上，不参与页面与卡片的底色。
class _Palette {
  const _Palette({
    required this.neutral,
    required this.brand,
    required this.brandLight,
    required this.brandContainer,
    required this.onBrandContainer,
    required this.onAccent,
    required this.attention,
    required this.attentionLight,
    required this.onAttentionLight,
  });

  final _NeutralPalette neutral;

  /// 主色，用在链接、选中状态与可操作的元素上。
  final Color brand;

  /// 主色的浅底，用在用户气泡、标签、导航指示块与 Markdown 表头上。
  final Color brandLight;

  /// 主色的容器底色，用在选中芯片与次要按钮上。
  final Color brandContainer;

  /// 压在 [brandContainer] 上的文字颜色。
  final Color onBrandContainer;

  /// 压在主色上的文字或图标颜色。
  final Color onAccent;

  /// 提醒色，用在需要留意的状态与链接的悬停上。
  final Color attention;

  /// 提醒色的浅底，用在草稿与优先这类需要留意的标签上。
  final Color attentionLight;

  /// 压在 [attentionLight] 上的文字颜色。
  final Color onAttentionLight;

  Brightness get brightness => neutral.brightness;
  Color get ink => neutral.ink;
  Color get muted => neutral.muted;
  Color get paper => neutral.paper;
  Color get card => neutral.card;
  Color get code => neutral.code;
  Color get border => neutral.border;
  Color get inputBorder => neutral.inputBorder;
  Color get raised => neutral.raised;
  Color get selectedSurface => neutral.selectedSurface;
  Color get error => neutral.error;
  Color get onError => neutral.onError;
}

_NeutralPalette _neutral(Brightness brightness) =>
    brightness == Brightness.light ? _lightNeutral : _darkNeutral;

/// 主色家族的派生规则。色值全部在 OKLCH 里算：混色只改明度与彩度、保留
/// 主色的色相，调明度时也保留色相，换成别的主题色不会串到邻近的色相上。
///
/// 浅色：主色浅底取主色在白色上的 8%，主色容器取 15%；容器上的文字把主色
/// 压暗 0.10 的明度，压在主色上的文字是白色。
///
/// 深色：主色浅底取主色在黑色上的 15%，主色容器取 30%，明度都不低于抬高的
/// 表面，浅底在纯黑页面与深灰卡片上都看得出来；容器上的文字把主色提亮 0.10，
/// 压在主色上的文字把主色压暗 0.10，压暗之后不足 4.5:1 时继续压暗到够为止，
/// 深色主色的明度低于 0.40 时会压到接近黑色，颜色向黑靠拢。所以明度低于 0.40
/// 的深色主色改用深灰的容器承载浅底，容器上的文字提亮到主色与黑之间。
///
/// 石墨是无彩色，主色家族直接取中性灰：浅色用抬高的表面与容器上的正文色，
/// 深色用抬高的表面与卡片。
///
/// 提醒色默认用琥珀，主题色为橙时改用紫色，避免草稿标签与主按钮同色；这条
/// 规则写在这里，页面不判断。
_Palette _palette(_NeutralPalette neutral, ZhixinAccent accent) {
  final light = neutral.brightness == Brightness.light;
  final primary = accent.primaryFor(neutral.brightness);
  final brand = _Oklch.of(primary);
  final Color brandLight;
  final Color brandContainer;
  final Color onBrandContainer;
  final Color onAccent;
  if (accent._achromatic) {
    // 中性灰的主色家族不按色相生成，直接用表面与卡片两档。
    brandLight = neutral.raised;
    brandContainer = neutral.card;
    onBrandContainer = primary;
    onAccent = light ? const Color(0xFFFFFFFF) : neutral.card;
  } else if (light) {
    brandLight = _place(brand, 0.08, const Color(0xFFFFFFFF));
    brandContainer = _place(brand, 0.15, const Color(0xFFFFFFFF));
    onBrandContainer = _withLightness(brand, brand.lightness - 0.10);
    onAccent = const Color(0xFFFFFFFF);
  } else if (brand.lightness >= 0.40) {
    // 主色在纯黑页面上的 15% 与在深灰卡片上的 15% 取亮的一侧，浅底在这两种
    // 底上都分得出来。
    const darkFloor = 0.33;
    final floor = math.max(darkFloor, _Oklch.of(neutral.raised).lightness);
    brandLight = _place(brand, 0.15, const Color(0xFF000000), floor: floor);
    brandContainer = _place(brand, 0.30, const Color(0xFF000000), floor: floor);
    onBrandContainer = _withLightness(brand, brand.lightness + 0.10);
    onAccent = _onDarkPrimary(brand);
  } else {
    // 深色主色偏暗：浅底与容器同为深灰，文字取亮的一侧。
    brandLight = _place(
      _Oklch(math.max(brand.lightness + 0.08, 0.45), brand.chroma, brand.hue),
      0.35,
      neutral.card,
    );
    brandContainer = brandLight;
    onBrandContainer = _withLightness(brand, brand.lightness + 0.45);
    onAccent = _withLightness(brand, brand.lightness - 0.10);
  }
  final attention = accent == ZhixinAccent.orange
      ? (light ? _violetAttentionLight : _violetAttentionDark)
      : (light ? _amberAttentionLight : _amberAttentionDark);
  return _Palette(
    neutral: neutral,
    brand: primary,
    brandLight: brandLight,
    brandContainer: brandContainer,
    onBrandContainer: onBrandContainer,
    onAccent: onAccent,
    attention: attention.$1,
    attentionLight: attention.$2,
    onAttentionLight: attention.$3,
  );
}

/// 提醒色的三档，依次是提醒色本身、浅底与压在浅底上的文字。
const (Color, Color, Color) _amberAttentionLight = (
  Color(0xFFB45309),
  Color(0xFFFEF1DF),
  Color(0xFF7A3A06),
);
const (Color, Color, Color) _amberAttentionDark = (
  Color(0xFFF0B070),
  Color(0xFF3A2A14),
  Color(0xFFFFDDB8),
);
const (Color, Color, Color) _violetAttentionLight = (
  Color(0xFF7C3AED),
  Color(0xFFF1EAFE),
  Color(0xFF4C1D95),
);
const (Color, Color, Color) _violetAttentionDark = (
  Color(0xFFA78BFA),
  Color(0xFF2A1F4D),
  Color(0xFFE4DAFF),
);

/// [color] 的 [amount] 份与其余 [base] 混色：只混明度与彩度，色相仍取
/// [color]，因为 [base] 是纯白或纯黑，不带色相。[floor] 给出明度下限，
/// 深色下的混色不会暗到与页面分不出。
Color _place(_Oklch color, double amount, Color base, {double floor = 0}) {
  final target = _Oklch.of(base);
  final lightness =
      target.lightness + (color.lightness - target.lightness) * amount;
  return _Oklch(
    math.max(lightness, floor),
    color.chroma * amount,
    color.hue,
  ).toColor();
}

/// 只换明度，色相与彩度照旧；明度超出 0–1 时取到端点上。
Color _withLightness(_Oklch color, double lightness) =>
    _Oklch(lightness.clamp(0, 1), color.chroma, color.hue).toColor();

/// 深色主色上的文字：主色明度减去 0.10 仍能压出 4.5:1 时取这一档，否则一路
/// 压暗到满足 4.5:1 为止。主色越暗，字与主色的间距就越大，最暗到黑色。
Color _onDarkPrimary(_Oklch brand) {
  final primary = brand.toColor();
  Color at(double lightness) => _withLightness(brand, lightness);
  if (_contrastOf(at(brand.lightness - 0.10), primary) >= 4.5) {
    return at(brand.lightness - 0.10);
  }
  var low = 0.0;
  var high = brand.lightness - 0.10;
  for (var i = 0; i < 20; i++) {
    final middle = (low + high) / 2;
    if (_contrastOf(at(middle), primary) >= 4.5) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return at(high);
}

/// 两个颜色的 WCAG 对比度，亮的一方作分子。
double _contrastOf(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

/// OKLCH 颜色：明度 0–1、彩度与非负、色相按度。用 sRGB 与线性 RGB 之间的
/// 标准换算，超出色域时按端点截断。
class _Oklch {
  const _Oklch(this.lightness, this.chroma, this.hue);

  factory _Oklch.of(Color color) {
    final rgb = color.toARGB32();
    double channel(int shift) {
      final value = ((rgb >> shift) & 0xFF) / 255;
      return value <= 0.04045
          ? value / 12.92
          : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
    }

    final r = channel(16);
    final g = channel(8);
    final b = channel(0);
    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
    final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    final chroma = math.sqrt(a * a + bb * bb);
    return _Oklch(
      lightness,
      chroma,
      chroma < 1e-6 ? 0 : (math.atan2(bb, a) * 180 / math.pi + 360) % 360,
    );
  }

  final double lightness;
  final double chroma;
  final double hue;

  Color toColor() {
    final radians = hue * math.pi / 180;
    final a = chroma * math.cos(radians);
    final b = chroma * math.sin(radians);
    final l = lightness + 0.3963377774 * a + 0.2158037573 * b;
    final m = lightness - 0.1055613458 * a - 0.0638541728 * b;
    final s = lightness - 0.0894841775 * a - 1.2914855480 * b;
    final red =
        4.0767416621 * l * l * l -
        3.3077115913 * m * m * m +
        0.2309699292 * s * s * s;
    final green =
        -1.2684380046 * l * l * l +
        2.6097574011 * m * m * m -
        0.3413193965 * s * s * s;
    final blue =
        -0.0041960863 * l * l * l -
        0.7034186147 * m * m * m +
        1.7076147010 * s * s * s;
    double encode(double value) {
      final clamped = value.clamp(0.0, 1.0);
      final encoded = clamped <= 0.0031308
          ? 12.92 * clamped
          : 1.055 * math.pow(clamped, 1 / 2.4) - 0.055;
      return encoded.clamp(0.0, 1.0);
    }

    return Color.from(
      alpha: 1,
      red: encode(red),
      green: encode(green),
      blue: encode(blue),
    );
  }
}

double _cbrt(double value) => value < 0
    ? -math.pow(-value, 1 / 3).toDouble()
    : math.pow(value, 1 / 3).toDouble();
