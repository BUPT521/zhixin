import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/markdown_text.dart';
import 'package:zhixin/ui/theme.dart';

Widget app(String text) => MaterialApp(
  theme: zhixinTheme,
  // 正文的字号与颜色现在从 Forui 主题的应用扩展读取；Markdown 内部仍要
  // Material 的 ThemeData 取 GptMarkdownThemeData，所以两层都装上。
  home: forui.FTheme(
    data: zhixinForuiTheme,
    child: Scaffold(body: MarkdownText(text)),
  ),
);

void main() {
  testWidgets('回答里的外链图片不构建网络图片，只留可点击的提示', (tester) async {
    await tester.pumpWidget(app('看图 ![截图](https://example.com/a.png) 和这段文字'));

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('外链图片'), findsOneWidget);
    expect(find.textContaining('和这段文字'), findsOneWidget);
  });

  testWidgets('非 http 图片也不构建图片，提示不提供打开', (tester) async {
    await tester.pumpWidget(app('看图 ![截图](data:image/png;base64,AAAA)'));

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('图片未加载'), findsOneWidget);
  });
}
