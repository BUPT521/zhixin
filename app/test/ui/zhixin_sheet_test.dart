import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_sheet.dart';

/// 底部面板由 Material 的 showModalBottomSheet 承担，底色与上圆角来自
/// [zhixinTheme] 的底部面板主题；这里用最小应用验证打开与关闭。
void main() {
  Widget app() => MaterialApp(
    theme: zhixinTheme,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showZhixinSheet<void>(
          context: context,
          builder: (context) =>
              const Padding(padding: EdgeInsets.all(16), child: Text('面板内容')),
        ),
        child: const Text('打开面板'),
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
}
