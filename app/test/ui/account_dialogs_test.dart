import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/account_dialogs.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_dialog.dart';

/// 删除账号前的重新认证：对话框要求输入当前密码，取消返回空值，密码留空时
/// 留在对话框里提示而不是直接提交；删除之前读过积分余额时提示余额无法使用。
void main() {
  String? result;

  setUp(() => result = null);

  Widget app({int? remainingPoints}) => forui.FTheme(
    data: zhixinForuiTheme,
    child: MaterialApp(
      theme: zhixinTheme,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await askDeleteAccountPassword(
              context,
              remainingPoints: remainingPoints,
            );
          },
          child: const Text('删除账号'),
        ),
      ),
    ),
  );

  Future<void> openDialog(WidgetTester tester, {int? remainingPoints}) async {
    await tester.pumpWidget(app(remainingPoints: remainingPoints));
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

  testWidgets('有积分余额时提示剩余积分无法使用，也无法退款', (tester) async {
    await openDialog(tester, remainingPoints: 120);
    expect(find.textContaining('还有 120 积分'), findsOneWidget);
    expect(find.textContaining('无法使用，也无法退款'), findsOneWidget);
  });

  testWidgets('余额未知时不提示积分', (tester) async {
    await openDialog(tester);
    expect(find.textContaining('积分'), findsNothing);
  });

  testWidgets('余额为 0 时不提示积分', (tester) async {
    await openDialog(tester, remainingPoints: 0);
    expect(find.textContaining('积分'), findsNothing);
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
