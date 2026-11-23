import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/memory_dialog.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_dialog.dart';

/// 记忆编辑框的写入上限：表的 CHECK 放到 2000 字是给步骤 5 的总预算预留，
/// 步骤 5 之前手动写入与工具写入一样限 200 字（ADR-0051）。
void main() {
  MemoryDraft? result;

  setUp(() => result = null);

  Widget app() => forui.FTheme(
    data: zhixinForuiTheme,
    child: MaterialApp(
      theme: zhixinTheme,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showZhixinDialog<MemoryDraft>(
              context: context,
              builder: (_) => const MemoryDialog(),
            );
          },
          child: const Text('记一条'),
        ),
      ),
    ),
  );

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.widgetWithText(TextButton, '记一条'));
    await tester.pumpAndSettle();
  }

  Future<void> enterContent(WidgetTester tester, String content) async {
    await tester.enterText(find.byType(EditableText).last, content);
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
  }

  testWidgets('超过 200 字时不保存，留在弹窗里提示并说明怎么办', (tester) async {
    await openDialog(tester);
    await enterContent(tester, '长' * 201);
    await tapSave(tester);

    expect(find.textContaining('一条记忆最多 200 字'), findsOneWidget);
    expect(find.byType(ZhixinDialogLayout), findsOneWidget, reason: '弹窗不关闭');
    expect(result, isNull);
  });

  testWidgets('正好 200 字可以保存', (tester) async {
    await openDialog(tester);
    final content = '长' * 200;
    await enterContent(tester, content);
    await tapSave(tester);

    expect(result?.content, content);
    expect(find.byType(ZhixinDialogLayout), findsNothing);
  });
}
