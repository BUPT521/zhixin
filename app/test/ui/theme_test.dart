import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';

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
    expect(
      markdown.styleSheet.table?.headerBackground,
      zhixinTheme.colorScheme.primaryContainer,
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
        greaterThanOrEqualTo(3),
        reason: '${theme.brightness} 的主色在页面底色上要能看见',
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
        _contrast(scheme.onSecondary, scheme.secondary),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness} 的次色按钮文字要能读清',
      );
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
      zhixinDarkTheme.colorScheme.primaryContainer,
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
