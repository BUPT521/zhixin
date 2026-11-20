import 'dart:async';
import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/platform/data_package_export.dart';
import 'package:zhixin/ui/data_version_page.dart';
import 'package:zhixin/ui/learning_page.dart';

import 'package:zhixin/data/db/sql.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('生产装配的仓库受数据库独占访问协调', (tester) async {
    await openApp(tester);

    await tester.runAsync(() async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final lock = scope!.testing.gate.exclusive(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      var writeFinished = false;
      final write = scope!.testing.tasks
          .createGoal(title: '恢复期间的新目标')
          .then((_) => writeFinished = true);
      await Future<void>.delayed(Duration.zero);
      expect(writeFinished, isFalse);

      release.complete();
      await lock;
      await write;
      expect(writeFinished, isTrue);
    });
  });

  testWidgets('手动导出只向平台传临时文件路径，恢复后仓库可以继续读写', (tester) async {
    await openApp(tester);

    await tester.runAsync(() async {
      final beforeId = await scope!.testing.tasks.createGoal(title: '恢复前保留目标');
      final settings = scope!.settings.edit;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('com.zhixin.app/data_package');
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final exported = File('${directory.path}/export.zip');
      late File temporary;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'save');
        final arguments = call.arguments as Map;
        expect(arguments.keys, unorderedEquals(['path', 'fileName']));
        expect(arguments['fileName'], settings.exportFileName());
        temporary = File(arguments['path'] as String);
        await temporary.copy(exported.path);
        return 'content://test/export.zip';
      });
      final uri = await saveDataPackage(
        fileName: settings.exportFileName(),
        writePackage: scope!.data.versions.backupRepository,
      );
      expect(uri, 'content://test/export.zip');
      expect(await temporary.parent.exists(), isFalse);

      final restoredBytes = await settings.restoreBytes(
        await exported.readAsBytes(),
      );
      expect(restoredBytes.isSuccess, isTrue);

      expect((await scope!.testing.tasks.goalById(beforeId))?.title, '恢复前保留目标');
      final points = await scope!.data.versions.restorePoints();
      expect(points, hasLength(1));
      expect(await File(points.single.path).exists(), isTrue);
      expect(points.single.head, await scope!.data.versions.currentHead());
      final afterId = await scope!.testing.tasks.createGoal(title: '恢复后新增目标');
      expect((await scope!.testing.tasks.goalById(afterId))?.title, '恢复后新增目标');

      // 恢复点用同一条整库恢复流程，可以真正回到保存时的数据。
      final restoredPoint = await scope!.data.versions.restore(
        await File(points.single.path).readAsBytes(),
      );
      expect(restoredPoint.isSuccess, isTrue);
      expect(await scope!.testing.tasks.goalById(afterId), isNull);
      expect((await scope!.testing.tasks.goalById(beforeId))?.title, '恢复前保留目标');
    });
  });

  testWidgets('当前数据已导入时，图片缓存写入失败仍会刷新数据', (tester) async {
    await openApp(tester);

    await tester.runAsync(() async {
      final state = scope!;
      final bytes = Uint8List.fromList([1, 2, 3]);
      final hash = AssetStore.hashBytes(bytes);
      final recordId = await state.testing.db.transaction((txn) async {
        await insertRow(txn, 'conversation', {
          'id': 'conv-1',
          'title': '带图的学习记录',
          'entry_kind': 'photo',
          'status': 'open',
          'created_at': '2026-11-10T10:00:00',
          'updated_at': '2026-11-10T10:00:00',
        });
        await AssetStore().putBytes(txn, hash, bytes);
        await insertRow(txn, 'message', {
          'id': 'msg-1',
          'conversation_id': 'conv-1',
          'role': 'user',
          'content': '',
          'image_paths_json': '["$hash"]',
          'created_at': '2026-11-10T10:00:00',
        });
        return 'conv-1';
      });
      final exported = File('${directory.path}/current.zip');
      await state.data.versions.exportCurrentData(exported.path);
      await deleteRows(
        state.testing.db,
        'conversation',
        where: 'id = ?',
        whereArgs: [recordId],
      );
      expect(await selectRows(state.testing.db, 'message'), isEmpty);

      final images = Directory(state.paths.imagesDir);
      await images.rename('${images.path}.original');
      await File(images.path).writeAsString('占用缓存目录');
      final versionBefore = state.dataVersion.value;
      final headBefore = await state.data.versions.currentHead();

      final imported = await state.data.versions.importCurrentData(
        await exported.readAsBytes(),
        expectedHead: headBefore,
      );

      expect(imported.valueOrNull, contains('数据已导入'));
      expect(await state.data.versions.currentHead(), greaterThan(headBefore));
      expect(await selectRows(state.testing.db, 'message'), hasLength(1));
      expect(state.dataVersion.value, versionBefore + 1);
    });
  });

  testWidgets('恢复之后迟到的提示不写进恢复后的数据', (tester) async {
    final ai = DelayedHelpAi();
    await openApp(tester, ai: ai, size: const Size(390, 1200));

    final questionId = (await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '求条件概率'),
    ))!;
    // 先在提示之前留一份整库备份，恢复之后题目与作答仍回到这一份。
    final backup = File('${directory.path}/恢复前.zip');
    await tester.runAsync(
      () => scope!.data.versions.backupRepository(backup.path),
    );
    final bytes = (await tester.runAsync(backup.readAsBytes))!;
    final attemptId = (await tester.runAsync(
      () => scope!.chat.learning.view(questionId),
    ))!.openAttempt!.id;

    await tester.tap(find.text('记录').last);
    await settle(tester);
    final record = find.widgetWithText(forui.FTile, '求条件概率');
    await tester.tap(find.descendant(of: record, matching: find.text('继续作答')));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);

    // 提示进入模型请求后一直等在这里，用例在等待期间整库恢复。
    await tester.tap(find.text('提示'));
    for (var i = 0; i < 80 && !ai.entered.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(ai.entered.isCompleted, isTrue);

    await tester.runAsync(() => scope!.data.versions.restore(bytes));
    ai.resume.complete();
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (find.textContaining('获取帮助没有完成').evaluate().isNotEmpty) break;
    }

    // 迟到的回答留在页面之外，恢复后的作答仍没有帮助记录。
    expect(find.textContaining('获取帮助没有完成'), findsOneWidget);
    expect(find.text('恢复之后才回来的提示'), findsNothing);
    // 读库加超时：以后这条路径再出问题时应报失败，而不是把整条用例挂住。
    final attempt = await tester.runAsync(
      () => scope!.testing.attempts
          .attemptById(attemptId)
          .timeout(const Duration(seconds: 10)),
    );
    expect(attempt!.helps, isEmpty);
    expect(tester.takeException(), isNull);
    // 整库恢复后首页与三栏在后台重读，等这些读取结束再关库，避免关库等读锁。
    await settle(tester);
  });

  testWidgets('数据版本页列出提交历史、留存与两类数据包入口', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => scope!.testing.tasks.createGoal(title: '版本页目标'),
    );
    await openMineEntry(tester, '数据版本');
    expect(find.byType(DataVersionPage), findsOneWidget);
    expect(find.text('命名当前版本'), findsOneWidget);
    expect(find.text('导出当前数据'), findsOneWidget);
    expect(find.text('备份版本库'), findsOneWidget);
    expect(find.text('提交历史'), findsOneWidget);
    expect(find.textContaining('条保留提交'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页列出恢复点并标明可以回到恢复前', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.tasks.createGoal(title: '恢复点目标');
      final backup = File('${directory.path}/restore.zip');
      await scope!.data.versions.backupRepository(backup.path);
      await scope!.data.versions.restore(await backup.readAsBytes());
    });
    await openMineEntry(tester, '数据版本');

    final section = find.text('恢复点');
    await tester.scrollUntilVisible(
      section,
      200,
      scrollable: find
          .descendant(
            of: find.byType(DataVersionPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(section, findsOneWidget);
    expect(find.textContaining('整库恢复前自动保存'), findsOneWidget);
    expect(find.textContaining('最多保留最近 5 份'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复版本后把新增的恢复提交带回提交历史', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.tasks.createGoal(title: '恢复前的目标');
      for (var index = 0; index < 20; index++) {
        await scope!.testing.db.transaction((txn) async {
          await insertRow(txn, 'conversation', {
            'id': 'conv-restore-$index',
            'title': '恢复前的讨论 $index',
            'entry_kind': 'text',
            'status': 'open',
            'created_at': '2026-11-10 09:00:00',
            'updated_at': '2026-11-10 09:00:00',
          });
        });
      }
    });
    await openMineEntry(tester, '数据版本');

    final page = find.byType(DataVersionPage);
    final scrollable = find
        .descendant(of: page, matching: find.byType(Scrollable))
        .first;
    // 停在整个列表的最下面，此时新增的提交在视野之外。
    final oldest = find.byIcon(FLucideIcons.ellipsis).last;
    await tester.scrollUntilVisible(oldest, 300, scrollable: scrollable);
    await settle(tester);
    await tester.tap(oldest);
    await settle(tester);
    await tester.tap(find.text('恢复到这个版本'));
    await settle(tester);
    await tester.tap(find.text('恢复'));
    await settle(tester);

    final newest = find.text('恢复版本（HEAD）');
    expect(newest, findsOneWidget);
    final view = tester.getRect(page);
    final rect = tester.getRect(newest);
    expect(rect.top, greaterThanOrEqualTo(view.top));
    expect(rect.bottom, lessThanOrEqualTo(view.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页直接禁用不能撤销的提交并说明原因', (tester) async {
    await openApp(tester);
    await tester.runAsync(
      () => insertRow(scope!.testing.db, 'conversation', {
        'id': 'conv-1',
        'title': '不能撤销的讨论',
        'entry_kind': 'text',
        'status': 'open',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
    );
    await openMineEntry(tester, '数据版本');

    await tester.scrollUntilVisible(
      find.text('提交历史'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(DataVersionPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(FLucideIcons.ellipsis).first);
    await settle(tester);
    final items = tester.widgetList<forui.FTile>(
      find.ancestor(
        of: find.text('撤销这次操作'),
        matching: find.byType(forui.FTile),
      ),
    );
    expect(items.any((item) => item.enabled == false), isTrue);
    expect(find.text('“conversation”的改动暂不支持单项撤销'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('截止时间保存后立即生效，撤销后设置与时间口径一起刷新', (tester) async {
    await openApp(tester);
    await openMineEntry(tester, '设置');
    final cutoffField = selectField<int>('每天的截止时间');
    await tester.scrollUntilVisible(
      cutoffField,
      260,
      scrollable: settingsScrollable(),
    );
    expect(scope!.timePolicy.cutoffHour, 4);

    await tester.ensureVisible(cutoffField);
    await tester.pumpAndSettle();
    await tester.tap(cutoffField);
    await settle(tester);
    await tester.tap(find.text('0 点').last);
    await settle(tester);
    expect(scope!.timePolicy.cutoffHour, 0);

    final head = await tester.runAsync(
      () => scope!.data.versions.currentHead(),
    );
    final result = await tester.runAsync(
      () => scope!.data.undo.undoCommit(head!),
    );
    expect(result!.applied, isTrue, reason: result.message);
    await settle(tester);
    expect(scope!.timePolicy.cutoffHour, 4);
    expect(tester.widget<EditableText>(cutoffField).controller.text, '4 点');
    expect(tester.takeException(), isNull);
  });
}
