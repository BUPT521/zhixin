import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/markdown_text.dart';
import 'package:zhixin/ui/theme.dart';

Widget app(String text, {bool streaming = false}) => MaterialApp(
  theme: zhixinTheme,
  // 正文的字号与颜色现在从 Forui 主题的应用扩展读取；Markdown 内部仍要
  // Material 的 ThemeData 取 GptMarkdownThemeData，所以两层都装上。
  home: forui.FTheme(
    data: zhixinForuiTheme,
    child: Scaffold(body: MarkdownText(text, streaming: streaming)),
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

  testWidgets('追加流式正文时复用前面的段落、代码块和列表', (tester) async {
    const prefix =
        '已完成的段落\n\n'
        '```dart\n第一行代码\n\n第二行代码\n```\n\n'
        '1. 列表首行\n\n   同一项的补充段落\n\n';
    await tester.pumpWidget(app('$prefix还在写', streaming: true));
    final completedParagraph = find.text('已完成的段落', findRichText: true);
    final code = find.textContaining('第一行代码\n\n第二行代码', findRichText: true);
    final listItem = find.textContaining('同一项的补充段落', findRichText: true);
    final before = [
      completedParagraph,
      code,
      listItem,
    ].map(tester.widget).toList();

    await tester.pumpWidget(app('$prefix还在写的尾段', streaming: true));
    expect(find.text('还在写的尾段', findRichText: true), findsOneWidget);
    for (final (index, block) in [completedParagraph, code, listItem].indexed) {
      expect(tester.widget(block), same(before[index]));
    }
    expect(find.byType(StreamingHint), findsOneWidget);

    await tester.pumpWidget(app('$prefix还在写的尾段'));
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(StreamingHint), findsNothing);
    expect(code, findsOneWidget);
    expect(listItem, findsOneWidget);
  });
}
