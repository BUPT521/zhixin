import 'package:forui/forui.dart' as forui;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/ui/cloud_sync_prompts.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/zhixin_dialog.dart';

/// 首次基线上传、恢复自动同步、整库恢复之后的重新对齐与云端快照重建的确认框：
/// 确认返回 true，取消返回 false。
void main() {
  bool? baselineResult;
  bool? autoSyncResult;
  bool? restoreResult;
  bool? snapshotRebuildResult;

  setUp(() {
    baselineResult = null;
    autoSyncResult = null;
    restoreResult = null;
    snapshotRebuildResult = null;
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
            TextButton(
              onPressed: () async {
                restoreResult = await confirmRestoreAlignment(context);
              },
              child: const Text('恢复后同步'),
            ),
            TextButton(
              onPressed: () async {
                snapshotRebuildResult = await confirmSnapshotRebuild(
                  context,
                  localCommits: 2,
                );
              },
              child: const Text('按快照重建'),
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
    expect(find.textContaining('本机现在有 3 条提交'), findsOneWidget);
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

  testWidgets('恢复之后的同步确认说明云端会改成恢复后的内容', (tester) async {
    await open(tester, '恢复后同步');
    expect(find.byType(ZhixinDialogLayout), findsOneWidget);
    expect(find.text('同步会把云端改成恢复后的内容'), findsOneWidget);
    expect(find.textContaining('恢复之前推送的多余记录会从云端删除'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '同步并覆盖云端'));
    await tester.pumpAndSettle();
    expect(restoreResult, isTrue);
  });

  testWidgets('恢复之后的同步确认取消返回 false', (tester) async {
    await open(tester, '恢复后同步');
    await tester.tap(find.widgetWithText(forui.FButton, '取消'));
    await tester.pumpAndSettle();
    expect(restoreResult, isFalse);
  });

  testWidgets('去云端快照重建确认说明会改写本机历史，取消返回 false', (tester) async {
    await open(tester, '按快照重建');
    expect(find.byType(ZhixinDialogLayout), findsOneWidget);
    expect(find.text('云端历史已经压缩，这台设备要从云端快照重建'), findsOneWidget);
    expect(find.textContaining('本机还没有推送的 2 条改动会作为新提交重放'), findsOneWidget);
    expect(find.textContaining('取消则不同步，本机数据保持不变'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '取消'));
    await tester.pumpAndSettle();
    expect(snapshotRebuildResult, isFalse);
  });

  testWidgets('去云端快照重建确认点按快照重建返回 true', (tester) async {
    await open(tester, '按快照重建');
    await tester.tap(find.widgetWithText(forui.FButton, '按快照重建'));
    await tester.pumpAndSettle();
    expect(snapshotRebuildResult, isTrue);
  });
}
