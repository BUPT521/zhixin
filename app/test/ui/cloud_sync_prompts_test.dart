import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/cloud_sync_prompts.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_dialog.dart';

/// 首次基线上传与恢复自动同步的两个确认框：确认返回 true，取消返回 false。
void main() {
  bool? baselineResult;
  bool? autoSyncResult;

  setUp(() {
    baselineResult = null;
    autoSyncResult = null;
  });

  Widget app() => forui.FTheme(
    data: zhixinForuiTheme,
    child: MaterialApp(
      theme: zhixinTheme,
      home: Builder(
        builder: (context) => Column(
          children: [
            TextButton(
              onPressed: () async {
                baselineResult = await confirmBaselineUpload(
                  context,
                  localCommits: 3,
                );
              },
              child: const Text('首次同步'),
            ),
            TextButton(
              onPressed: () async {
                autoSyncResult = await confirmEnableAutoSync(
                  context,
                  accountLabel: 'a@example.com',
                );
              },
              child: const Text('开启自动同步'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, String label) async {
    await tester.pumpWidget(app());
    await tester.tap(find.widgetWithText(TextButton, label));
    await tester.pumpAndSettle();
  }

  testWidgets('基线上传确认说明会上传本机记录，取消返回 false', (tester) async {
    await open(tester, '首次同步');
    expect(find.byType(ZhixinDialogLayout), findsOneWidget);
    expect(find.textContaining('本机现有的 3 条提交'), findsOneWidget);
    expect(find.textContaining('取消则不上传，并暂停自动同步'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '取消'));
    await tester.pumpAndSettle();
    expect(baselineResult, isFalse);
  });

  testWidgets('基线上传确认点上传并同步返回 true', (tester) async {
    await open(tester, '首次同步');
    await tester.tap(find.widgetWithText(forui.FButton, '上传并同步'));
    await tester.pumpAndSettle();
    expect(baselineResult, isTrue);
  });

  testWidgets('开启自动同步确认点名账号，取消保持暂停', (tester) async {
    await open(tester, '开启自动同步');
    expect(find.textContaining('a@example.com 对应的账号'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '取消'));
    await tester.pumpAndSettle();
    expect(autoSyncResult, isFalse);
  });

  testWidgets('开启自动同步确认点开启返回 true', (tester) async {
    await open(tester, '开启自动同步');
    await tester.tap(find.widgetWithText(forui.FButton, '开启'));
    await tester.pumpAndSettle();
    expect(autoSyncResult, isTrue);
  });
}
