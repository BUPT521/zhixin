part of 'theme.dart';

/// 某个主题色在某个亮度下的 Material 主题缓存：换过一次之后再回来直接取，
/// 切换与启动都不必重算。
final Map<(ZhixinAccent, Brightness), ThemeData> _materialThemes = {};

ThemeData _cachedMaterial(ZhixinAccent accent, Brightness brightness) =>
    _materialThemes.putIfAbsent((
      accent,
      brightness,
    ), () => _buildMaterial(accent, brightness));

ThemeData _buildMaterial(ZhixinAccent accent, Brightness brightness) =>
    _materialTheme(_tokensFor(accent, brightness));

/// 某个主题色的两套 Material 主题。
Map<Brightness, ThemeData> materialThemesFor(ZhixinAccent accent) => {
  Brightness.light: _cachedMaterial(accent, Brightness.light),
  Brightness.dark: _cachedMaterial(accent, Brightness.dark),
};

/// 回答正文与 Material 本地化用的主题；页面不再从它取字号与颜色。
final ThemeData zhixinTheme = _cachedMaterial(kDefaultAccent, Brightness.light);
final ThemeData zhixinDarkTheme = _cachedMaterial(
  kDefaultAccent,
  Brightness.dark,
);

/// gpt_markdown 仍按 Material 的 `ThemeData` 取样式与 `GptMarkdownThemeData`，
/// 这里用它需要的那部分，色值与字号同样来自 [_Palette] 与 [_textStyles]。
///
/// 色板直接由 [_Palette] 构造，不用 `ColorScheme.fromSeed`：从主色取种子时，
/// 没写出来的表面、容器与色调角色都会按主色的色相染色，背景与卡片就不再是
/// 中性灰。这里把所有会画到底色上的角色一次写全，`surfaceTint` 取透明，
/// 叠加色调不会再把底色染蓝。
ThemeData _materialTheme(_Tokens tokens) {
  final palette = tokens.palette;
  final text = tokens.text;
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
    // 开关是 Material 组件，轨道、圆钮与禁用态在这里配一次：关闭时轨道取
    // 容器描边色、圆钮取卡片底色，开启时轨道取主色、圆钮取压在主色上的文字
    // 色，深浅两套都分得出来；禁用态按 Material 的不透明度档位压暗。
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return states.contains(WidgetState.selected)
              ? palette.brand.withValues(alpha: 0.38)
              : palette.ink.withValues(alpha: 0.12);
        }
        return states.contains(WidgetState.selected)
            ? palette.brand
            : palette.border;
      }),
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return palette.ink.withValues(alpha: 0.38);
        }
        return states.contains(WidgetState.selected)
            ? palette.onAccent
            : palette.card;
      }),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
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
