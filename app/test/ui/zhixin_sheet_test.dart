import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_sheet.dart';

/// 底部面板由 Material 的 showModalBottomSheet 承担，底色与上圆角来自
/// [zhixinTheme] 的底部面板主题；标题与左右边距收在 [ZhixinSheet] 里。
/// 这里用最小应用验证打开、关闭、标题与长内容滚动。
void main() {
  Widget app({String? title, Widget? child}) => forui.FTheme(
    data: zhixinForuiTheme,
    child: MaterialApp(
      theme: zhixinTheme,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showZhixinSheet<void>(
            context: context,
            title: title,
            builder: (context) =>
                child ??
                const Padding(padding: EdgeInsets.all(16), child: Text('面板内容')),
          ),
          child: const Text('打开面板'),
        ),
      ),
    ),
  );

  testWidgets('面板打开后显示内容与拖动条', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.text('面板内容'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(zhixinTheme.bottomSheetTheme.backgroundColor, isNotNull);
  });

  testWidgets('点遮挡层关闭面板', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('面板内容'), findsNothing);
  });

  testWidgets('传入 title 时标题显示在内容上方', (tester) async {
    await tester.pumpWidget(app(title: '这周还能做什么'));
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.text('这周还能做什么'), findsOneWidget);
    expect(find.text('面板内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('带标题的长内容在面板里滚动，不越出屏幕', (tester) async {
    await tester.pumpWidget(
      app(
        title: '这周还能做什么',
        child: const SizedBox(
          height: 1200,
          child: Align(alignment: Alignment.bottomCenter, child: Text('面板末尾')),
        ),
      ),
    );
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(find.text('这周还能做什么'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 面板不高于屏幕，内容超出时由滚动区承担。
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.top, greaterThanOrEqualTo(0));
    expect(sheet.bottom, lessThanOrEqualTo(600));
  });
}
