import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';

/// 色板在 `ui/theme.dart` 里是私有的，测试按同一份色值核对：浅色底是纯白、
/// 深色底是纯黑，底色与表面不带色相，默认主题色是蓝色。
const _lightPaper = Color(0xFFFFFFFF);
const _darkPaper = Color(0xFF000000);
const _lightBrand = Color(0xFF2563EB);
const _darkBrand = Color(0xFF5B9BFF);
const _darkAttention = Color(0xFFF0B070);

/// 蓝色主题其余主色家族的色值。这几档由主色派生，蓝色主题的取值就是换
/// 主题色之前的基线，其他主题色按同一套规则生成。
const _lightOnPrimary = Color(0xFFFFFFFF);
const _darkOnPrimary = Color(0xFF050021);
const _blueLightContainer = Color(0xFFEDF3FF);
const _blueLightContainerDeep = Color(0xFFDDE9FF);
const _blueLightOnContainer = Color(0xFF0442C8);
const _blueDarkLight = Color(0xFF2E3642);
const _blueDarkContainer = Color(0xFF26364E);
const _blueDarkOnContainer = Color(0xFF7ABBFF);

/// 深色外观的正文、卡片、抬高表面、描边与提醒色；这几个角色不随主题色改变，
/// 换成别的主题色之后仍是同一组色值。
const _darkInk = Color(0xFFECECEE);
const _darkMuted = Color(0xFF9D9DA5);
const _darkCard = Color(0xFF131315);
const _darkRaised = Color(0xFF1E1E21);
const _darkCode = Color(0xFF0B0B0D);
const _darkBorder = Color(0xFF2A2A2E);
const _darkInputBorder = Color(0xFF45454B);
const _darkError = Color(0xFFFFB4AB);
const _darkOnError = Color(0xFF690005);
const _lightError = Color(0xFFBA1A1A);

/// 提醒色：默认琥珀，主题色为橙时改用紫色。
const _lightAttention = Color(0xFFB45309);
const _lightAttentionContainer = Color(0xFFFEF1DF);
const _lightOnAttentionContainer = Color(0xFF7A3A06);
const _darkAttentionContainer = Color(0xFF3A2A14);
const _darkOnAttentionContainer = Color(0xFFFFDDB8);
const _violetAttention = Color(0xFF7C3AED);
const _violetAttentionContainer = Color(0xFFF1EAFE);
const _violetOnAttentionContainer = Color(0xFF4C1D95);
const _darkVioletAttention = Color(0xFFA78BFA);
const _darkVioletAttentionContainer = Color(0xFF2A1F4D);
const _darkVioletOnAttentionContainer = Color(0xFFE4DAFF);

/// 六种主题色在浅色与深色外观下的主色。
const _accents = {
  ZhixinAccent.blue: (Color(0xFF2563EB), Color(0xFF5B9BFF)),
  ZhixinAccent.moss: (Color(0xFF245C48), Color(0xFF6FCF97)),
  ZhixinAccent.violet: (Color(0xFF7C3AED), Color(0xFFA78BFA)),
  ZhixinAccent.rose: (Color(0xFFBE185D), Color(0xFFF472B6)),
  ZhixinAccent.orange: (Color(0xFFC2410C), Color(0xFFFB923C)),
  ZhixinAccent.graphite: (Color(0xFF18181B), Color(0xFFE4E4E7)),
};

/// 换主题色时不该动的颜色角色，深浅各一组。
const _neutralRoles = [
  Color(0xFFFFFFFF), // 浅色页面
  Color(0xFFFFFFFF), // 浅色卡片
  Color(0xFFF4F4F5), // 浅色抬高表面与代码块
  Color(0xFF111111), // 浅色正文
  Color(0xFF6B6B72), // 浅色次要文字
  Color(0xFFC9C9CE), // 浅色输入框描边
  Color(0xFFE6E6E8), // 浅色卡片描边
  _lightError,
  Color(0xFFFFFFFF), // 压住错误色
];

ZhixinColors _colorsOf({
  ZhixinAccent accent = ZhixinAccent.blue,
  bool dark = false,
}) => foruiThemesFor(
  accent,
)[dark ? Brightness.dark : Brightness.light]!.extension<ZhixinTheme>().colors;

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
    expect(zhixin.text.titleMedium.fontWeight, FontWeight.w600);
    // 字重分三档：一屏一个的主标题最重，页面标题与节标题次之，正文与二级
    // 页面标题回到常规。
    expect(zhixin.text.headlineMedium.fontWeight, FontWeight.w700);
    expect(zhixin.text.pageTitle.fontWeight, FontWeight.w500);
    expect(zhixin.text.headlineSmall.fontWeight, FontWeight.w600);
    expect(zhixin.text.titleLarge.fontSize, 22);
    expect(zhixin.text.titleLarge.fontWeight, FontWeight.w400);
    // 页面颜色与 Material 的 ColorScheme 同名同值，只从 Forui 主题取。
    expect(zhixin.colors.primary, zhixinTheme.colorScheme.primary);
    expect(zhixin.colors.error, zhixinTheme.colorScheme.error);
    expect(zhixin.colors.card, zhixinForuiTheme.colors.card);
    expect(zhixin.radius.card, const BorderRadius.all(Radius.circular(20)));
    // Forui 的表单与列表按 body.sm 排正文，取的是同一份 bodyMedium 字号。
    expect(zhixinForuiTheme.typography.body.sm.fontSize, 14);
    // 页面文字与 Forui 控件都不指定字族，中文与西文都跟随手机系统字体。
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

  test('蓝色主题的色值与换主题色前的基线逐项一致', () {
    final light = _colorsOf();
    final dark = _colorsOf(dark: true);
    expect(light.primary, _lightBrand);
    expect(dark.primary, _darkBrand);
    expect(light.onPrimary, _lightOnPrimary);
    // 由 OKLCH 换算出来的色值与同一份十六进制字面量在浮点上差最后一位，按
    // 取整之后的 8 位取值核对。
    expect(_hex(dark.onPrimary), _hex(_darkOnPrimary));
    expect(
      _hex(zhixinTheme.colorScheme.primaryFixed),
      _hex(_blueLightContainer),
    );
    expect(
      _hex(zhixinDarkTheme.colorScheme.primaryFixed),
      _hex(_blueDarkLight),
    );
    expect(_hex(light.primaryContainer), _hex(_blueLightContainerDeep));
    expect(_hex(dark.primaryContainer), _hex(_blueDarkContainer));
    expect(_hex(light.onPrimaryContainer), _hex(_blueLightOnContainer));
    expect(_hex(dark.onPrimaryContainer), _hex(_blueDarkOnContainer));

    final neutral = [
      'surface',
      'card',
      'surfaceContainerHigh',
      'onSurface',
      'onSurfaceVariant',
      'outline',
      'outlineVariant',
      'error',
      'onError',
    ];
    final lightRoles = [
      light.surface,
      light.card,
      light.surfaceContainerHigh,
      light.onSurface,
      light.onSurfaceVariant,
      light.outline,
      light.outlineVariant,
      light.error,
      light.onError,
    ];
    final darkRoles = [
      dark.surface,
      dark.card,
      dark.surfaceContainerHigh,
      dark.onSurface,
      dark.onSurfaceVariant,
      dark.outline,
      dark.outlineVariant,
      dark.error,
      dark.onError,
    ];
    expect(lightRoles, _neutralRoles.take(9));
    expect(darkRoles, [
      _darkPaper,
      _darkCard,
      _darkRaised,
      _darkInk,
      _darkMuted,
      _darkInputBorder,
      _darkBorder,
      _darkError,
      _darkOnError,
    ], reason: '${neutral.join('、')} 与换主题色前的基线一致');
    expect(zhixinDarkTheme.colorScheme.surfaceContainerLowest, _darkCode);
    expect(light.attention, _lightAttention);
    expect(light.attentionContainer, _lightAttentionContainer);
    expect(light.onAttentionContainer, _lightOnAttentionContainer);
    expect(dark.attention, _darkAttention);
    expect(dark.attentionContainer, _darkAttentionContainer);
    expect(dark.onAttentionContainer, _darkOnAttentionContainer);
  });

  test('六个主题色只用各自的主色，底色与表面都不变', () {
    for (final MapEntry(key: accent, value: (lightPrimary, darkPrimary))
        in _accents.entries) {
      final light = _colorsOf(accent: accent);
      final dark = _colorsOf(accent: accent, dark: true);
      expect(light.primary, lightPrimary, reason: '${accent.label} 浅色主色');
      expect(dark.primary, darkPrimary, reason: '${accent.label} 深色主色');
      expect(ZhixinAccent.values, contains(accent));
      // 底色、卡片、描边、文字与错误色与蓝色主题同值，换主题色不回退中性底。
      expect(
        [
          light.surface,
          light.card,
          light.surfaceContainerHigh,
          light.onSurface,
          light.onSurfaceVariant,
          light.outline,
          light.outlineVariant,
          light.error,
          light.onError,
        ],
        _neutralRoles,
        reason: '${accent.label} 浅色的中性色与错误色',
      );
      expect(
        [
          dark.surface,
          dark.card,
          dark.surfaceContainerHigh,
          dark.onSurface,
          dark.onSurfaceVariant,
          dark.outline,
          dark.outlineVariant,
          dark.error,
          dark.onError,
        ],
        [
          _darkPaper,
          _darkCard,
          _darkRaised,
          _darkInk,
          _darkMuted,
          _darkInputBorder,
          _darkBorder,
          _darkError,
          _darkOnError,
        ],
        reason: '${accent.label} 深色的中性色与错误色',
      );
      // 页面与卡片在深浅两套里都是纯白或纯黑。
      expect(light.surface, _lightPaper);
      expect(dark.surface, _darkPaper);
      // 石墨是无彩色，主色家族也不带色相。
      if (accent == ZhixinAccent.graphite) {
        for (final color in [
          light.primaryContainer,
          light.onPrimaryContainer,
          dark.primaryContainer,
          dark.onPrimaryContainer,
          light.primary,
          dark.primary,
        ]) {
          expect(_neutral(color), isTrue, reason: '$color 不该带色相');
        }
      }
    }
  });

  test('六个主题色 × 浅深两套的对比度都够读清', () {
    for (final accent in ZhixinAccent.values) {
      for (final dark in [false, true]) {
        final theme = foruiThemesFor(
          accent,
        )[dark ? Brightness.dark : Brightness.light]!;
        final colors = theme.extension<ZhixinTheme>().colors;
        final where = '${accent.label}${dark ? '深色' : '浅色'}';
        expect(
          _contrast(colors.onPrimary, colors.primary),
          greaterThanOrEqualTo(4.5),
          reason: '$where 的主按钮文字',
        );
        expect(
          _contrast(colors.onPrimaryContainer, colors.primaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: '$where 的选中项与容器文字',
        );
        // 链接与图标放宽到 3:1；主色也按 4.5:1 核对，正文里出现主色时同样能读。
        expect(
          _contrast(colors.primary, colors.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$where 的主色作为文字压在页面上',
        );
        expect(
          _contrast(colors.primary, colors.card),
          greaterThanOrEqualTo(4.5),
          reason: '$where 的主色作为文字压在卡片上',
        );
        // 链接悬停时只降透明度，混到底色上仍要能看出颜色还在。半透明不与底色
        // 混合的浅色主色本身就在 2:1 上下，这一条按 2:1 核对。
        final hovered = Color.alphaBlend(
          colors.primary.withValues(alpha: 0.5),
          colors.surface,
        );
        expect(
          _contrast(hovered, colors.surface),
          greaterThanOrEqualTo(2),
          reason: '$where 的链接悬停态',
        );
        // 容器文字被 Forui 悬停时会提亮或压暗，仍要留出可读的下限。
        expect(
          _contrast(
            theme.colors.hover(colors.onPrimaryContainer),
            colors.primaryContainer,
          ),
          greaterThanOrEqualTo(3),
          reason: '$where 的容器文字悬停态',
        );
        expect(
          _contrast(colors.attention, colors.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$where 的提醒色作为文字',
        );
        expect(
          _contrast(colors.onAttentionContainer, colors.attentionContainer),
          greaterThanOrEqualTo(4.5),
          reason: '$where 的草稿标签文字',
        );
      }
    }
  });

  test('主色浅底与容器在深色下也看得出边界', () {
    for (final accent in ZhixinAccent.values) {
      if (accent == ZhixinAccent.graphite) continue;
      final theme = foruiThemesFor(accent)[Brightness.dark]!;
      final colors = theme.extension<ZhixinTheme>().colors;
      final material = materialThemesFor(accent)[Brightness.dark]!;
      for (final background in [colors.surface, colors.card]) {
        expect(
          _contrast(material.colorScheme.primaryFixed, background),
          greaterThan(1.4),
          reason: '${accent.label} 的主色浅底压在页面上要分得出来',
        );
      }
      expect(
        _contrast(colors.primaryContainer, colors.card),
        greaterThan(1.15),
        reason: '${accent.label} 的主色容器要分得出来',
      );
    }
  });

  test('提醒色默认琥珀，主题色为橙时改用紫色', () {
    for (final accent in ZhixinAccent.values) {
      final light = _colorsOf(accent: accent);
      final dark = _colorsOf(accent: accent, dark: true);
      final orange = accent == ZhixinAccent.orange;
      expect(light.attention, orange ? _violetAttention : _lightAttention);
      expect(
        light.attentionContainer,
        orange ? _violetAttentionContainer : _lightAttentionContainer,
      );
      expect(
        light.onAttentionContainer,
        orange ? _violetOnAttentionContainer : _lightOnAttentionContainer,
      );
      expect(dark.attention, orange ? _darkVioletAttention : _darkAttention);
      expect(
        dark.attentionContainer,
        orange ? _darkVioletAttentionContainer : _darkAttentionContainer,
      );
      expect(
        dark.onAttentionContainer,
        orange ? _darkVioletOnAttentionContainer : _darkOnAttentionContainer,
      );
      if (orange) {
        // 草稿标签的主色不能再与主按钮同色相。
        expect(_warmDominant(light.attentionContainer), isFalse);
        expect(_warmDominant(dark.attentionContainer), isFalse);
      }
    }
  });

  test('换主题色时 Forui、Material 与 Markdown 一起换，缓存按主题色分开', () {
    for (final accent in ZhixinAccent.values) {
      final (lightPrimary, _) = _accents[accent]!;
      final foruiLight = foruiThemesFor(accent)[Brightness.light]!;
      final materialLight = materialThemesFor(accent)[Brightness.light]!;
      expect(foruiLight.colors.primary, lightPrimary);
      expect(materialLight.colorScheme.primary, lightPrimary);
      final markdown = materialLight.extension<GptMarkdownThemeData>()!;
      // 链接、表头底与引用条都随主题色走，与页面读到的颜色同值。
      expect(markdown.linkColor, lightPrimary);
      expect(
        markdown.styleSheet.table?.headerBackground,
        materialLight.colorScheme.primaryFixed,
      );
      expect(markdown.styleSheet.blockQuote?.barColor, lightPrimary);
      // 同一主题色再取一次拿到同一个实例，换回来时不必重新生成。
      expect(foruiThemesFor(accent)[Brightness.light], same(foruiLight));
      expect(materialThemesFor(accent)[Brightness.light], same(materialLight));
    }
    // 默认的蓝色主题就是 [ZhixinAccent.blue] 生成的那一份。
    expect(
      zhixinForuiTheme,
      same(foruiThemesFor(ZhixinAccent.blue)[Brightness.light]),
    );
    expect(
      zhixinTheme,
      same(materialThemesFor(ZhixinAccent.blue)[Brightness.light]),
    );
    expect(
      zhixinDarkForuiTheme,
      same(foruiThemesFor(ZhixinAccent.blue)[Brightness.dark]),
    );
    expect(
      zhixinDarkTheme,
      same(materialThemesFor(ZhixinAccent.blue)[Brightness.dark]),
    );
  });

  test('主题色按名称解析，不认识的名称回到蓝色', () {
    for (final accent in ZhixinAccent.values) {
      expect(ZhixinAccent.parse(accent.name), accent);
    }
    expect(ZhixinAccent.parse(null), ZhixinAccent.blue);
    expect(ZhixinAccent.parse(''), ZhixinAccent.blue);
    expect(ZhixinAccent.parse('teal'), ZhixinAccent.blue);
    expect(ZhixinAccent.parse('Blue'), ZhixinAccent.blue);
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

/// 颜色的 8 位十六进制取值，带透明度。
String _hex(Color color) =>
    '0x${color.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0')}';

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
