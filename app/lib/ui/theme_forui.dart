part of 'theme.dart';

/// 某个主题色在某个亮度下的 Forui 主题缓存：换过一次之后再回来直接取，
/// 切换与启动都不必重算。
final Map<(ZhixinAccent, Brightness), forui.FThemeData> _foruiThemes = {};

forui.FThemeData _cachedForui(ZhixinAccent accent, Brightness brightness) =>
    _foruiThemes.putIfAbsent((
      accent,
      brightness,
    ), () => _buildForui(accent, brightness));

forui.FThemeData _buildForui(ZhixinAccent accent, Brightness brightness) =>
    _foruiTheme(_tokensFor(accent, brightness));

/// 某个主题色的两套 Forui 主题：应用根部把浅色与深色分别交给 Material 与
/// Forui，主题色一换就换成这一份。
Map<Brightness, forui.FThemeData> foruiThemesFor(ZhixinAccent accent) => {
  Brightness.light: _cachedForui(accent, Brightness.light),
  Brightness.dark: _cachedForui(accent, Brightness.dark),
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

forui.FThemeData _foruiTheme(_Tokens tokens) {
  final palette = tokens.palette;
  final base = palette.brightness == Brightness.light
      ? forui.FTheme.neutral.light.touch
      : forui.FTheme.neutral.dark.touch;
  final colors = _foruiColors(base.colors, palette);
  final zhixin = tokens.colors;
  final icons = base.icons;
  final text = tokens.text;
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
    extensions: [ZhixinTheme(text: text, colors: zhixin)],
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
