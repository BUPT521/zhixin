import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';

/// 色板在 `ui/theme.dart` 里是私有的，测试按同一份色值核对：浅色底是纯白、
/// 深色底是纯黑，底色与表面不带色相，主色是蓝色。
const _lightPaper = Color(0xFFFFFFFF);
const _darkPaper = Color(0xFF000000);
const _lightBrand = Color(0xFF2563EB);
const _darkBrand = Color(0xFF5B9BFF);
const _darkAttention = Color(0xFFF0B070);

void main() {
  test('路由过渡按平台分工，安卓交给预测性返回', () {
    final builders = zhixinTheme.pageTransitionsTheme.builders;
    expect(
      builders[TargetPlatform.android],
      isA<ZhixinAndroidPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.macOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.windows],
      isA<ZhixinPageTransitionsBuilder>(),
    );
  });
  testWidgets('回答正文的 Markdown 沿用应用配色与字号', (tester) async {
    late GptMarkdownThemeData markdown;
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: Builder(
          builder: (context) {
            markdown = Theme.of(context).extension<GptMarkdownThemeData>()!;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(markdown.linkColor, zhixinTheme.colorScheme.primary);
    expect(markdown.h1!.fontSize, lessThanOrEqualTo(20));
    expect(markdown.h2!.fontSize!, lessThan(markdown.h1!.fontSize!));
    expect(markdown.h6!.fontSize!, lessThanOrEqualTo(markdown.h3!.fontSize!));
    // 表头用主色浅底，与主色容器同属蓝色一族。
    expect(
      markdown.styleSheet.table?.headerBackground,
      zhixinTheme.colorScheme.primaryFixed,
    );
    expect(markdown.styleSheet.table?.overflow, TableOverflow.wrap);
  });

  test('深浅两套主题的正文、主色与底色都有足够对比度', () {
    for (final theme in [zhixinTheme, zhixinDarkTheme]) {
      final scheme = theme.colorScheme;
      expect(
        _contrast(scheme.onSurface, scheme.surface),
        greaterThanOrEqualTo(7),
        reason: '${theme.brightness} 的正文在页面底色上要能读清',
      );
      expect(
        _contrast(scheme.primary, scheme.surface),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness} 的主色在页面底色上按正文级别要能读清',
      );
      expect(
        _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness} 的容器文字要能读清',
      );
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness} 的按钮文字要能读清',
      );
      expect(
        _contrast(scheme.secondary, scheme.surface),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness} 的提醒色当作文字贴在页面上要能读清',
      );
      expect(
        _contrast(scheme.outline, scheme.surface),
        greaterThanOrEqualTo(1.4),
        reason: '${theme.brightness} 的描边在页面底色上要能看出边界',
      );
    }
  });

  test('底色与表面不带色相，主色是蓝色', () {
    final light = zhixinForuiTheme.extension<ZhixinTheme>().colors;
    final dark = zhixinDarkForuiTheme.extension<ZhixinTheme>().colors;
    expect(light.surface, _lightPaper);
    expect(dark.surface, _darkPaper);
    expect(light.primary, _lightBrand);
    expect(dark.primary, _darkBrand);
    // 浅色下页面与卡片同为白色，卡片靠描边分开。
    expect(light.card, light.surface);
    for (final color in [
      light.card,
      dark.card,
      light.surfaceContainerHigh,
      dark.surfaceContainerHigh,
    ]) {
      expect(_neutral(color), isTrue, reason: '$color 不该带色相');
    }
    // 主色与提醒色的浅底只带各自一族的色相，不与底色混出别的颜色。
    for (final color in [
      light.primaryContainer,
      dark.primaryContainer,
      zhixinTheme.colorScheme.primaryFixed,
    ]) {
      expect(_blueDominant(color), isTrue, reason: '$color 应当是蓝色一族');
    }
    expect(_warmDominant(light.attentionContainer), isTrue);
    // 深色下的蓝色文字压在页面与卡片上都按正文级别可读。
    for (final background in [dark.surface, dark.card]) {
      expect(_contrast(dark.primary, background), greaterThanOrEqualTo(4.5));
    }
  });

  test('Material 的色板由色板直接构造，不带主色染色', () {
    for (final theme in [zhixinTheme, zhixinDarkTheme]) {
      final scheme = theme.colorScheme;
      expect(scheme.surfaceTint, Colors.transparent);
      // 表面与其余容器不再从主色派生，取页面、卡片与抬高表面这三档中性灰。
      final layers = [
        scheme.surface,
        scheme.surfaceDim,
        scheme.surfaceBright,
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ];
      for (final color in layers) {
        expect(_neutral(color), isTrue, reason: '$color 不该带主色的色相');
      }
    }
  });

  test('Forui 的悬停、按下与禁用态沿基色的色相，出现时也不偏色', () {
    for (final (theme, brand) in [
      (zhixinForuiTheme, _lightBrand),
      (zhixinDarkForuiTheme, _darkBrand),
    ]) {
      final colors = theme.colors;
      // 主色的悬停与禁用只改明度与透明度，仍然是同一族蓝色。
      for (final state in [colors.hover(brand), colors.disable(brand)]) {
        expect(_blueDominant(state), isTrue, reason: '$state 不该偏到别的颜色');
      }
      // 正文与次要文字是中性的，派生之后也不该变成蓝或绿。`disable` 只降透明度，
      // 0.5 的灰度保留 8 位的 128 时会偏到蓝紫一档，按百分之六的余量算作中性。
      for (final state in [
        colors.disable(colors.mutedForeground),
        colors.hover(colors.mutedForeground),
        colors.hover(colors.foreground),
      ]) {
        expect(_neutral(state, tolerance: 16), isTrue, reason: '$state 不该带色相');
      }
      // 描边是中性灰，悬停与禁用之后仍然不带色相。
      for (final state in [
        colors.hover(colors.border),
        colors.disable(colors.border),
      ]) {
        expect(_neutral(state, tolerance: 16), isTrue, reason: '$state 不该带色相');
      }
    }
  });

  testWidgets('深色主题替换背景、卡片与 Markdown 配色', (tester) async {
    late GptMarkdownThemeData markdown;
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinDarkTheme,
        home: Builder(
          builder: (context) {
            markdown = Theme.of(context).extension<GptMarkdownThemeData>()!;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(zhixinDarkTheme.brightness, Brightness.dark);
    expect(
      zhixinDarkTheme.scaffoldBackgroundColor,
      isNot(zhixinTheme.scaffoldBackgroundColor),
    );
    // 卡片色只从 Forui 主题的应用扩展取；Material 的 ThemeData 不再保留一份
    // 没有界面读取的 cardTheme。
    expect(
      zhixinDarkForuiTheme.extension<ZhixinTheme>().colors.card,
      isNot(zhixinForuiTheme.extension<ZhixinTheme>().colors.card),
    );
    expect(markdown.linkColor, zhixinDarkTheme.colorScheme.primary);
    expect(
      markdown.styleSheet.table?.headerBackground,
      zhixinDarkTheme.colorScheme.primaryFixed,
    );
    expect(
      markdown.styleSheet.codeBlock?.backgroundColor?.computeLuminance(),
      lessThan(0.1),
    );
  });

  testWidgets('页面读到的字号与颜色来自 Forui 主题扩展', (tester) async {
    late ZhixinTheme zhixin;
    await tester.pumpWidget(
      MaterialApp(
        theme: zhixinTheme,
        home: forui.FTheme(
          data: zhixinForuiTheme,
          child: Builder(
            builder: (context) {
              zhixin = context.zhixin;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    // 页面字号与 Material 原来的文本样式同值，改成 Forui 之后版面不变。
    expect(zhixin.text.bodySmall.fontSize, 12);
    expect(zhixin.text.bodyMedium.fontSize, 14);
    expect(zhixin.text.bodyMedium.height, 1.5);
    // 字重只有常规与强调两档：标题、标签与主标题都是强调，正文与二级页面
    // 标题是常规；中文不写字距，每一档都取 0。
    expect(zhixin.text.bodyMedium.fontWeight, FontWeight.w400);
    expect(zhixin.text.titleMedium.fontWeight, FontWeight.w600);
    expect(zhixin.text.headlineMedium.fontWeight, FontWeight.w600);
    expect(zhixin.text.pageTitle.fontWeight, FontWeight.w600);
    expect(zhixin.text.headlineSmall.fontWeight, FontWeight.w600);
    expect(zhixin.text.titleLarge.fontSize, 22);
    expect(zhixin.text.titleLarge.fontWeight, FontWeight.w600);
    expect(zhixin.text.pageTitle.fontSize, 26);
    for (final style in [
      zhixin.text.headlineMedium,
      zhixin.text.headlineSmall,
      zhixin.text.pageTitle,
      zhixin.text.titleLarge,
      zhixin.text.titleMedium,
      zhixin.text.titleSmall,
      zhixin.text.bodyLarge,
      zhixin.text.bodyMedium,
      zhixin.text.bodySmall,
      zhixin.text.labelLarge,
      zhixin.text.labelMedium,
      zhixin.text.labelSmall,
    ]) {
      expect(style.letterSpacing, 0);
    }
    // 页面颜色与 Material 的 ColorScheme 同名同值，只从 Forui 主题取。
    expect(zhixin.colors.primary, zhixinTheme.colorScheme.primary);
    expect(zhixin.colors.error, zhixinTheme.colorScheme.error);
    expect(zhixin.colors.card, zhixinForuiTheme.colors.card);
    expect(zhixin.radius.card, const BorderRadius.all(Radius.circular(20)));
    // 容器描边取浅的一档，控件描边取深的一档；Forui 的全局描边跟着容器走。
    expect(zhixin.colors.outlineVariant, isNot(zhixin.colors.outline));
    expect(zhixinForuiTheme.colors.border, zhixin.colors.outlineVariant);
    expect(
      zhixin.colors.primarySoft,
      zhixinTheme.colorScheme.primaryFixed,
      reason: '主色浅底与 Material 的主色浅底同值',
    );
    // Forui 的表单与列表按 body.sm 排正文，取的是同一份 bodyMedium 字号。
    expect(zhixinForuiTheme.typography.body.sm.fontSize, 14);
    // 按钮标签只有强调字重，sm 的标签 12.5、其余尺寸 14；sm 的横向内边距 14、
    // 纵向 8，内容区最小高度仍是触摸布局的 40。
    for (final (size, fontSize, padding) in [
      (
        forui.FButtonSizeVariant.sm,
        12.5,
        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      (forui.FButtonSizeVariant.md, 14.0, null),
      (forui.FButtonSizeVariant.lg, 14.0, null),
    ]) {
      final style = zhixinForuiTheme.buttonStyles
          .resolve({forui.FButtonVariant.primary})
          .resolve({size});
      expect(style.contentStyle.textStyle.base.fontWeight, FontWeight.w600);
      expect(style.contentStyle.textStyle.base.fontSize, fontSize);
      if (padding != null) {
        expect(style.contentStyle.padding, padding);
      }
      expect(style.contentStyle.constraints.minHeight, 44, reason: '按钮统一 44 高');
    }
    // ghost 是文字按钮，用主色。
    expect(
      zhixinForuiTheme.buttonStyles
          .resolve({forui.FButtonVariant.ghost})
          .resolve({forui.FButtonSizeVariant.md})
          .contentStyle
          .textStyle
          .base
          .color,
      zhixin.colors.primary,
    );
    // 输入框未聚焦的边用控件描边，聚焦的边用主色；主题的 border 是容器描边，
    // 两者要分开。
    final field = zhixinForuiTheme.textFieldStyles.md;
    expect(
      (field.border.base as OutlineInputBorder).borderSide.color,
      zhixin.colors.outline,
    );
    expect(
      (field.border.base as OutlineInputBorder).borderSide.color,
      isNot(zhixinForuiTheme.colors.border),
    );
    expect(
      (field.border.resolve({
        forui.FTextFieldVariant.focused,
      }) as OutlineInputBorder).borderSide.color,
      zhixin.colors.primary,
    );
    expect(
      field.contentTextStyle.base.fontSize,
      zhixin.text.bodyMedium.fontSize,
    );
    // 列表项标题取 titleSmall，右侧箭头 16 用次要文字色。
    final tile = zhixinForuiTheme.tileStyles.primary;
    expect(
      tile.contentStyle.titleTextStyle.base.fontWeight,
      zhixin.text.titleSmall.fontWeight,
    );
    expect(tile.contentStyle.suffixIconStyle.base.size, 16);
    expect(
      tile.contentStyle.suffixIconStyle.base.color,
      zhixin.colors.onSurfaceVariant,
    ); // 页面文字与 Forui 控件都不指定字族，中文与西文都跟随手机系统字体。
    expect(zhixin.text.bodyMedium.fontFamily, isNull);
    expect(zhixinForuiTheme.typography.body.sm.fontFamily, isNull);
    expect(zhixinForuiTheme.typography.body.md.fontFamily, isNull);
    expect(zhixinForuiTheme.typography.display.xl2.fontFamily, isNull);
    // 只有时间与计数用 Inter 的等宽数字。
    expect(zhixin.text.figures.fontFamily, forui.FTypeface.defaultFontFamily);
    expect(
      zhixin.text.figures.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  test('留意标签与主色卡片上的文字都能读清', () {
    for (final theme in [zhixinForuiTheme, zhixinDarkForuiTheme]) {
      final colors = theme.extension<ZhixinTheme>().colors;
      expect(
        _contrast(colors.onAttentionContainer, colors.attentionContainer),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.attention, colors.attentionContainer),
        greaterThanOrEqualTo(3),
        reason: '草稿图标压在留意浅底上要能看见',
      );
      expect(
        _contrast(_darkAttention, zhixinDarkForuiTheme.colors.card),
        greaterThanOrEqualTo(4.5),
        reason: '深色下提醒色当作文字压在卡片上要能读清',
      );
      expect(
        _contrast(colors.onPrimary, colors.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.onSurfaceVariant, colors.card),
        greaterThanOrEqualTo(4.5),
        reason: '卡片上的次要文字要能读清',
      );
      expect(
        _contrast(colors.onPrimaryContainer, colors.primaryContainer),
        greaterThanOrEqualTo(4.5),
        reason: '选中项的文字要能读清',
      );
      expect(theme.scaffoldStyle.backgroundColor, colors.surface);
      expect(
        (theme.cardStyle.decoration as ShapeDecoration).color,
        colors.card,
      );
      expect(
        (theme.dialogStyle.decoration as ShapeDecoration).color,
        colors.card,
      );
    }
  });

  testWidgets('系统切到深色时 MaterialApp 选用深色主题', (tester) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    Future<ThemeData> themeUnder(Brightness brightness) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      late ThemeData theme;
      await tester.pumpWidget(
        MaterialApp(
          theme: zhixinTheme,
          darkTheme: zhixinDarkTheme,
          themeMode: ThemeMode.system,
          home: Builder(
            builder: (context) {
              theme = Theme.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      // 深浅切换走 AnimatedTheme，等动画结束再读当前主题。
      await tester.pumpAndSettle();
      return theme;
    }

    expect((await themeUnder(Brightness.dark)).brightness, Brightness.dark);
    expect((await themeUnder(Brightness.light)).brightness, Brightness.light);
  });
}

double _contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

/// 中性灰：三通道相差不超过 [tolerance]。明度越高差一档的通道数越少，
/// 深色卡片（`#131315`）这类取值三通道差两档，比值约百分之三，肉眼分不出色相。
bool _neutral(Color color, {int tolerance = 3}) {
  final rgb = color.toARGB32();
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  final high = [r, g, b].reduce((a, b) => a > b ? a : b);
  final low = [r, g, b].reduce((a, b) => a < b ? a : b);
  return high - low <= tolerance;
}

/// 蓝色一族：蓝通道最高，红与绿都比蓝低。
bool _blueDominant(Color color) {
  final rgb = color.toARGB32();
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  return b > r + 4 && b > g + 2;
}

/// 提醒色一族：橙与黄，红通道最高。
bool _warmDominant(Color color) {
  final rgb = color.toARGB32();
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  return r > g + 4 && g > b + 4;
}
