import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

void main() {
  testWidgets('整页等待的圈按 36 显示，颜色取主色', (tester) async {
    await tester.pumpWidget(
      forui.FTheme(
        data: zhixinForuiTheme,
        child: const MaterialApp(home: Scaffold(body: PageLoading())),
      ),
    );

    // Forui 的默认尺寸取正文字号，手机上只有 18；整页等待这一处显式放大，
    // 页面换成别家组件时尺寸也不能悄悄回到字号。
    final iconTheme = tester.widget<IconTheme>(
      find
          .descendant(
            of: find.byType(forui.FCircularProgress),
            matching: find.byType(IconTheme),
          )
          .first,
    );
    expect(iconTheme.data.size, PageLoading.diameter);
    expect(PageLoading.diameter, greaterThanOrEqualTo(32));
    expect(iconTheme.data.color, zhixinForuiTheme.colors.primary);
  });

  testWidgets('骨架卡片里按高度摆出标题、正文与标签的灰条', (tester) async {
    Future<int> barsIn(double rowHeight) async {
      await tester.pumpWidget(
        forui.FTheme(
          data: zhixinForuiTheme,
          child: MaterialApp(
            home: Scaffold(body: ListSkeleton(rows: 1, rowHeight: rowHeight)),
          ),
        ),
      );
      final bars = find.descendant(
        of: find.descendant(
          of: find.byType(ListSkeleton),
          matching: find.byType(ExcludeSemantics),
        ),
        matching: find.byType(DecoratedBox),
      );
      for (final bar in bars.evaluate()) {
        // 灰条都在卡片里面，不会把固定高度的卡片撑开。
        final box = bar.renderObject! as RenderBox;
        expect(box.size.height, lessThanOrEqualTo(rowHeight));
      }
      expect(tester.takeException(), isNull);
      return bars.evaluate().length;
    }

    // 矮卡片至少有标题与一行正文；越高摆得越多，最多四条。
    expect(await barsIn(64), 2);
    expect(await barsIn(88), 3);
    expect(await barsIn(168), 4);
    // 读屏仍只读到一句“正在读取”，灰条不进语义树。
    expect(find.bySemanticsLabel('正在读取'), findsOneWidget);
  });
}
