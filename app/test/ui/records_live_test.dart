import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/ui/copy.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

/// 记录页改成订阅之后，页面之外的写入与“回到旧数据”都由数据层重读（ADR-0014）。
///
/// 每日截止小时写在 `app_meta` 里，不在记录订阅的表里；页面另外监听数据版本，
/// 截止小时保存与撤销之后按新口径重排分组，这里补一条界面用例。
///
/// 写入放在 `tester.runAsync` 的真异步区，页面不点右上角刷新、不切栏、不返回重进；
/// 撤销与整库恢复同样只靠订阅带回重读。这里补的是 ADR-0014 实施结果里点名还缺的
/// 记录页订阅用例：材料、首页、记忆与系统学习已有各自的 `*_live_test.dart`。
///
/// 记录本身（`conversation`）不在单项撤销支持的表里（见
/// `application/undo_guards/revision_table_undo_guard.dart` 的允许表与
/// `workspace_flow_test` 里“conversation 的改动暂不支持单项撤销”那条），
/// 因此撤销这一段改用记录页同一屏里的目标筛选条验证：目标新增会形成可撤销的提交，
/// 撤销之后筛选条与记录归属都按当前数据重读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-records-live-');
    await disableTelemetryForTests(directory.path);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  tearDown(() async {
    await closeAppScope(scope, directory);
    scope = null;
  });

  /// 推进到所有读取、回填与过渡动画结束。
  ///
  /// 等的是应用自己的访问队列：页面读取都排在应用根上，队列清空之后再画几帧，
  /// 不再按固定时长反复等。
  Future<void> settle(WidgetTester tester) async {
    await settleFrames(tester, scope);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  /// 轮询到目标控件出现；读取与回填都在后台完成，不能只靠 pumpAndSettle 收尾。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 480,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await advanceAsync(
        tester,
        scope?.testing.gate,
        const Duration(milliseconds: 20),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 在真异步区里写库，再 pump 到订阅的重读回填完成。
  Future<T> seed<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    await settle(tester);
    return result as T;
  }

  Future<void> openApp(
    WidgetTester tester, {
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ZhixinApp(clock: clock ?? () => DateTime(2026, 11, 16, 9)),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await settle(tester);
  }

  /// 进入记录页；底栏“记录”与页头标题同名，取最后一个命中（底栏）。
  Future<void> openRecords(WidgetTester tester) async {
    await tester.tap(find.text(tabRecords).last);
    await settle(tester);
    expect(find.text(emptyRecords), findsOneWidget);
  }

  testWidgets('页面之外的写入之后，记录页不用手动刷新就出现这条记录', (tester) async {
    await openApp(tester);
    await openRecords(tester);

    // 一条讨论：标题写进记录页的列表标题。
    final conversationId = await seed(tester, () async {
      final id = await scope!.chat.discussion.createConversation(
        title: '条件概率为什么这么算',
      );
      await scope!.testing.conversations.append(
        id,
        role: MessageRole.user,
        content: '为什么条件概率要除以条件事件发生的概率？',
      );
      return id;
    });
    expect(conversationId, isNotEmpty);
    await pumpUntil(tester, find.text('条件概率为什么这么算'));
    expect(find.text(emptyRecords), findsNothing);

    // 一道题：带入题目同样形成一条学习记录，标题是题干。
    await seed(tester, () => scope!.chat.learning.capture(stem: '求条件概率'));
    await pumpUntil(tester, find.text('求条件概率'));
    expect(find.text('条件概率为什么这么算'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('改每日截止小时之后，记录页不用刷新就按新口径重新分组', (tester) async {
    // 凌晨一点半：默认 4 点截止，这条记录与“今天”都归到 11 月 19 日。
    await openApp(tester, clock: () => DateTime(2026, 11, 20, 1, 30));
    await openRecords(tester);
    await seed(tester, () async {
      final id = await scope!.chat.discussion.createConversation(
        title: '凌晨写下的讨论',
      );
      await scope!.testing.conversations.append(
        id,
        role: MessageRole.user,
        content: '这一条写在凌晨。',
      );
    });
    await pumpUntil(tester, find.text('凌晨写下的讨论'));
    expect(find.textContaining('今天 · 11月19日'), findsOneWidget);

    // 截止时间在“我的”里改，记录页此时不在前台；切回来时按新口径重排分组。
    await tester.tap(find.text(tabMine).last);
    await settle(tester);
    await tester.runAsync(() => scope!.settings.edit.saveCutoffHour(0));
    await settle(tester);
    await tester.tap(find.text(tabRecords).last);
    await settle(tester);
    expect(find.textContaining('今天 · 11月20日'), findsOneWidget);
    expect(find.textContaining('11月19日'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销与整库恢复之后，记录页按当前数据重读', (tester) async {
    await openApp(tester);
    await openRecords(tester);

    // 目标也是这一屏读出来的：新增之后筛选条多一个可点选的归属。
    await seed(tester, () => scope!.testing.tasks.createGoal(title: '线代复习'));
    await pumpUntil(tester, find.text('线代复习'));

    // 撤销这次提交：数据层回放改动之后按全部表补发一次，筛选条回到当前数据。
    final undone = await tester.runAsync(() async {
      final head = await scope!.data.versions.currentHead();
      return scope!.data.undo.undoCommit(head);
    });
    expect(undone!.applied, isTrue, reason: undone.message);
    await settle(tester);
    expect(find.text('线代复习'), findsNothing);
    expect(find.text('全部'), findsOneWidget);

    // 先留一份备份，再写一条不留在备份里的记录：恢复之后它应当从列表消失。
    await seed(tester, () async {
      final id = await scope!.chat.discussion.createConversation(
        title: '恢复前写下的讨论',
      );
      await scope!.testing.conversations.append(
        id,
        role: MessageRole.user,
        content: '这条记录会留在恢复点里。',
      );
    });
    await pumpUntil(tester, find.text('恢复前写下的讨论'));

    final backup = File('${directory.path}/恢复前.zip');
    await tester.runAsync(() async {
      await scope!.data.versions.backupRepository(backup.path);
    });
    final bytes = (await tester.runAsync(backup.readAsBytes))!;

    await seed(tester, () async {
      final id = await scope!.chat.discussion.createConversation(
        title: '恢复之后不该保留的讨论',
      );
      await scope!.testing.conversations.append(
        id,
        role: MessageRole.user,
        content: '这条记录写在备份之后。',
      );
    });
    await pumpUntil(tester, find.text('恢复之后不该保留的讨论'));

    // 整库恢复换掉连接：订阅跟着新连接重读，屏幕上的列表回到备份时的数据。
    final restored = await tester.runAsync(
      () => scope!.data.versions.restore(bytes),
    );
    expect(
      restored!.isSuccess,
      isTrue,
      reason: restored.failureOrNull?.message ?? '',
    );
    await settle(tester);
    await pumpUntil(tester, find.text('恢复前写下的讨论'));
    expect(find.text('恢复之后不该保留的讨论'), findsNothing);
    expect(tester.takeException(), isNull);
    // 让最后一次重读收尾，再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });
}
