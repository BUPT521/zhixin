import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/account_dialogs.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_dialog.dart';

/// 删除账号前的重新认证：对话框要求输入当前密码，取消返回空值，密码留空时
/// 留在对话框里提示而不是直接提交。
void main() {
  String? result;

  setUp(() => result = null);

  Widget app() => forui.FTheme(
    data: zhixinForuiTheme,
    child: MaterialApp(
      theme: zhixinTheme,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await askDeleteAccountPassword(context);
          },
          child: const Text('删除账号'),
        ),
      ),
    ),
  );

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.widgetWithText(TextButton, '删除账号'));
    await tester.pumpAndSettle();
  }

  testWidgets('先说明删除范围，再要求输入当前密码', (tester) async {
    await openDialog(tester);
    expect(find.byType(ZhixinDialogLayout), findsOneWidget);
    expect(find.text('当前密码'), findsOneWidget);
    expect(
      find.textContaining('会删除这个账号在服务端保存的备份、同步序列、附件与登录会话'),
      findsOneWidget,
    );
  });

  testWidgets('密码留空时留在对话框里提示，不返回结果', (tester) async {
    await openDialog(tester);
    await tester.tap(find.widgetWithText(forui.FButton, '删除账号'));
    await tester.pumpAndSettle();

    expect(find.byType(ZhixinDialogLayout), findsOneWidget);
    expect(find.text('填写当前密码后再删除'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('输入当前密码后返回密码并关闭对话框', (tester) async {
    await openDialog(tester);
    await tester.enterText(find.byType(EditableText), 'password123');
    await tester.tap(find.widgetWithText(forui.FButton, '删除账号'));
    await tester.pumpAndSettle();

    expect(find.byType(ZhixinDialogLayout), findsNothing);
    expect(result, 'password123');
  });

  testWidgets('取消返回空值，不执行删除', (tester) async {
    await openDialog(tester);
    await tester.tap(find.widgetWithText(forui.FButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.byType(ZhixinDialogLayout), findsNothing);
    expect(result, isNull);
  });
}
