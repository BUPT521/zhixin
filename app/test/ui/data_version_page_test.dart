import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/domain/rules/revision_actions.dart';
import 'package:zhixin/data/revisions/revision_digest.dart';
import 'package:zhixin/domain/models/revision_models.dart';
import 'package:zhixin/data/revisions/revision_service.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/ui/data_version_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';
import '../support/test_db.dart';

/// 数据版本页：提交列表按类型显示、同步覆盖、清理阻塞与两处危险操作确认。
///
/// 页面挂在真实的应用根上读整屏数据；`conflicts` 与 `historyBlockers` 在阶段 0
/// 还是空实现，覆盖“有冲突”与“清理被阻止”两种状态时由 [RevisionService]
/// 的替身给出结果（[DataVersionPage.revisions] 只用于这两类读取）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-data-version-');
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

  Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
    await settleFrames(tester, scope, rounds: rounds);
  }

  /// 打开数据版本页：应用根照生产装配，页面作为根页，省掉从“我的”点进来的几步。
  ///
  /// 需要替身时在这里用 [openTestRig] 搭一份库并交给页面；drift 的真实异步
  /// 只能在 [WidgetTester.runAsync] 里等，测试结束时由调用方关闭。
  Future<({AppScopeState scope, TestRig? rig, _StubRevisions? stub})> openPage(
    WidgetTester tester, {
    _StubRevisions Function(TestRig rig)? revisionsFactory,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final themeMode = ThemeModeController();
    addTearDown(themeMode.dispose);
    late AppScopeState appScope;
    TestRig? rig;
    _StubRevisions? stub;
    await tester.runAsync(() async {
      if (revisionsFactory != null) {
        rig = await openTestRig();
        stub = revisionsFactory(rig!);
      }
      await tester.pumpWidget(_host(themeMode, stub));
      appScope = tester.state<AppScopeState>(find.byType(AppScope));
      await appScope.ready;
    });
    await settle(tester);
    scope = appScope;
    return (scope: appScope, rig: rig, stub: stub);
  }

  Finder pageScrollable() => find
      .descendant(
        of: find.byType(DataVersionPage),
        matching: find.byType(Scrollable),
      )
      .first;

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 300, scrollable: pageScrollable());
    await settle(tester);
  }

  testWidgets('数据版本可以单独查看 AI 改动', (tester) async {
    final appScope = (await openPage(tester)).scope;
    await tester.runAsync(() async {
      final discussion = await appScope.chat.discussion.createConversation(
        title: '准备复习',
      );
      final message = await appScope.testing.conversations.append(
        discussion,
        role: MessageRole.assistant,
        content: '复习第八题。',
      );
      await appScope.chat.discussion.acceptNextStep(
        conversationId: discussion,
        messageId: message.id,
        draft: const NextStepDraft(title: '复习第八题', action: '重做一次'),
      );
      await appScope.study.plan.addGoal(title: '准备期末');
    });
    await settle(tester);
    await scrollTo(tester, find.text('筛选 AI 改动'));
    expect(find.textContaining(acceptNextStepAction), findsOneWidget);
    expect(find.textContaining('新建目标'), findsOneWidget);

    await tester.tap(find.text('筛选 AI 改动'));
    await settle(tester);
    expect(find.textContaining(acceptNextStepAction), findsOneWidget);
    expect(find.textContaining('新建目标'), findsNothing);

    await tester.tap(find.text('显示全部'));
    await settle(tester);
    expect(find.textContaining('新建目标'), findsOneWidget);
  });

  testWidgets('没有未处理的同步覆盖时不显示这一节', (tester) async {
    await openPage(tester);

    expect(find.byType(DataVersionPage), findsOneWidget);
    expect(find.text('同步覆盖'), findsNothing);
    expect(find.text('保留本机修改'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步覆盖写明内容与字段，保留本机修改之后这一节消失', (tester) async {
    final page = await openPage(
      tester,
      revisionsFactory: (rig) =>
          _StubRevisions(rig, pendingConflicts: [_titleConflict()]),
    );
    final stub = page.stub!;
    addTearDown(() => tester.runAsync(page.rig!.close));

    expect(find.text('同步覆盖'), findsOneWidget);
    expect(find.textContaining('本机原来的标题'), findsOneWidget);
    expect(find.textContaining('其他设备改后的标题'), findsWidgets);
    // 内容与字段名都走中文标签，界面上不出现英文表名与列名。
    expect(find.textContaining('标题'), findsWidgets);
    expect(find.textContaining('conversation'), findsNothing);
    expect(find.textContaining('title'), findsNothing);

    await tester.tap(find.text('保留本机修改'));
    await settle(tester);

    expect(stub.keptConflictId, 7);
    expect(find.text('同步覆盖'), findsNothing);
    expect(find.text('已把本机原来的值写回为一条新提交'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机已删的同步覆盖写明已经删除，不提供写回按钮', (tester) async {
    final page = await openPage(
      tester,
      revisionsFactory: (rig) =>
          _StubRevisions(rig, pendingConflicts: [_deletedLocallyConflict()]),
    );
    addTearDown(() => tester.runAsync(page.rig!.close));

    expect(find.text('同步覆盖'), findsOneWidget);
    expect(find.textContaining('已经删除'), findsWidgets);
    expect(find.text('保留本机修改'), findsNothing);
    expect(find.textContaining('conversation'), findsNothing);

    // 没有可以写回的本机值：确认之后把这条说明删掉。
    await tester.tap(find.text('知道了'));
    await settle(tester);
    expect(page.stub!.dismissedConflictId, 8);
    expect(find.text('同步覆盖'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理被阻止时把原因写进确认框并禁用确认', (tester) async {
    final page = await openPage(
      tester,
      revisionsFactory: (rig) =>
          _StubRevisions(rig, blockers: const ['还有 12 条修改没有同步到云端，先同步再清理']),
    );
    final stub = page.stub!;
    addTearDown(() => tester.runAsync(page.rig!.close));

    // 按留存清理：原因写在框里，确认按钮不可点。
    await scrollTo(tester, find.text('按留存清理'));
    await tester.tap(find.text('按留存清理'));
    await settle(tester);
    expect(find.text('现在还不能清理：'), findsOneWidget);
    expect(find.textContaining('还有 12 条修改没有同步到云端'), findsOneWidget);
    final confirm = find.ancestor(
      of: find.text('清理'),
      matching: find.byType(forui.FButton),
    );
    expect(tester.widget<forui.FButton>(confirm).onPress, isNull);
    expect(stub.blockerRequests, contains(false));
    await tester.tap(find.text('取消'));
    await settle(tester);

    // 清理本机历史读的是另一组阻塞原因（clearing: true）。
    await scrollTo(tester, find.text('清理本机历史'));
    await tester.tap(find.text('清理本机历史'));
    await settle(tester);
    expect(find.text('现在还不能清理：'), findsOneWidget);
    expect(stub.blockerRequests, contains(true));
    final clearConfirm = find.ancestor(
      of: find.text('清理'),
      matching: find.byType(forui.FButton),
    );
    expect(tester.widget<forui.FButton>(clearConfirm).onPress, isNull);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提交列表按提交类型显示中文标签与图标，动作文案作说明', (tester) async {
    final appScope = (await openPage(tester)).scope;
    await tester.runAsync(
      () => appScope.testing.tasks.createGoal(title: '版本标签目标'),
    );
    await settle(tester);

    // 初始基线来自首次打开库时写下的提交；写入来自刚建的目标，当前是 HEAD。
    expect(find.text('初始基线'), findsOneWidget);
    expect(find.text('写入（HEAD）'), findsOneWidget);
    expect(find.byIcon(FLucideIcons.flag), findsOneWidget);
    expect(find.byIcon(FLucideIcons.pencil), findsOneWidget);

    // 远端提交：动作文案由数据层记录，标签按 kind 显示成“其他设备”。来源设备
    // 只显示前 8 位，时间取服务端带来的作者时间（方案 3.12）。
    await tester.runAsync(
      () => appScope.data.revisions.applyRemoteCommit(
        uid: 'remote-lane-v-1',
        action: '其他设备新增讨论',
        actor: 'system',
        kind: RevisionKind.write,
        originDevice: 'device-0123456789abcdef',
        authoredAt: DateTime(2020, 1, 2, 3, 4),
        changes: [
          RevisionChange(
            commitId: 0,
            seq: 0,
            table: 'conversation',
            rowKey: 'conv-remote',
            op: ChangeOp.insert,
            after: typedRow({
              'id': 'conv-remote',
              'title': '其他设备追加的讨论',
              'entry_kind': 'text',
              'created_at': '2026-11-20 09:00:00',
              'updated_at': '2026-11-20 09:00:00',
            }),
          ),
        ],
      ),
    );
    await settle(tester);

    expect(find.text('写入（HEAD）'), findsOneWidget);
    expect(find.text('写入'), findsOneWidget);
    expect(find.textContaining('其他设备新增讨论'), findsOneWidget);
    expect(find.byIcon(FLucideIcons.cloudDownload), findsOneWidget);
    // 只有远端提交显示来源；本机提交（初始基线）不显示。
    expect(find.textContaining('来自另一台设备'), findsOneWidget);
    expect(find.textContaining('来自另一台设备 device-0'), findsOneWidget);
    expect(find.textContaining('1月2日 03:04'), findsOneWidget);
    // 整串设备标识不出现在界面上。
    expect(find.textContaining('0123456789abcdef'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('检查数据完整性通过时说明检查范围与核对结果', (tester) async {
    await openPage(tester);

    await scrollTo(tester, find.text('检查数据完整性'));
    await tester.tap(find.text('检查数据完整性'));
    await settle(tester);

    expect(find.text('数据完整性检查'), findsOneWidget);
    expect(find.textContaining('检查范围：从最近的检查点把变更明细重放到 HEAD'), findsOneWidget);
    expect(find.textContaining('通过：重放得到的摘要与当前数据一致'), findsOneWidget);
    expect(find.textContaining('共核对'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await settle(tester);
    expect(find.text('数据完整性检查'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发现问题时列出第几处不一致与建议，导出前检查让用户决定是否继续', (tester) async {
    final page = await openPage(
      tester,
      revisionsFactory: (rig) =>
          _StubRevisions(rig, integrityProblems: const ['提交 3 的哈希与变更明细不一致']),
    );
    addTearDown(() => tester.runAsync(page.rig!.close));
    final saves = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.zhixin.app/data_package');
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      saves.add((call.arguments as Map)['fileName'] as String);
      return 'content://test/repository.zip';
    });

    // 手动入口：逐条列出第几处不一致，并给出处理建议。
    await scrollTo(tester, find.text('检查数据完整性'));
    await tester.tap(find.text('检查数据完整性'));
    await settle(tester);
    expect(find.text('数据完整性检查'), findsOneWidget);
    expect(find.textContaining('发现 1 处不一致'), findsOneWidget);
    expect(find.textContaining('第 1 处：提交 3 的哈希与变更明细不一致'), findsOneWidget);
    expect(find.textContaining('建议：'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await settle(tester);

    // 导出前自动检查：先说明，再让用户选取消或继续。
    await scrollTo(tester, find.text('备份版本库'));
    await tester.tap(find.text('备份版本库'));
    await settle(tester);
    expect(find.text('备份版本库前发现不一致'), findsOneWidget);
    expect(find.textContaining('第 1 处：提交 3 的哈希与变更明细不一致'), findsOneWidget);
    expect(find.text('仍然备份版本库'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('已取消备份'), findsOneWidget);
    expect(saves, isEmpty, reason: '取消之后不生成备份文件');

    // 继续导出：仍然生成备份。
    await tester.tap(find.text('备份版本库'));
    await settle(tester);
    await tester.tap(find.text('仍然备份版本库'));
    await settle(tester, rounds: 40);
    expect(saves, hasLength(1));
    expect(
      find.textContaining('已备份版本库：content://test/repository.zip'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除命名版本与清理本机历史都先弹确认，命名版本说明写清清理时保留', (tester) async {
    final appScope = (await openPage(tester)).scope;
    await tester.runAsync(
      () async => appScope.data.revisions.name(
        await appScope.data.versions.currentHead(),
        label: '版本一',
      ),
    );
    await settle(tester);

    await scrollTo(tester, find.text('版本一'));
    expect(find.textContaining('命名后在清理本机历史时保留'), findsOneWidget);

    // 删除命名版本：先确认，取消之后名称仍在。
    final named = find.ancestor(
      of: find.text('版本一'),
      matching: find.byType(forui.FTile),
    );
    await tester.tap(
      find.descendant(of: named.first, matching: find.byIcon(FLucideIcons.x)),
    );
    await settle(tester);
    expect(find.text('删除命名版本'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('版本一'), findsOneWidget);

    // 清理本机历史：同样先确认，取消之后历史仍在。
    await scrollTo(tester, find.text('清理本机历史'));
    await tester.tap(find.text('清理本机历史'));
    await settle(tester);
    expect(find.text('清理本机历史'), findsNWidgets(2));
    expect(find.text('清理'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('提交历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('留存一节按保留天数选择，改动写入设置', (tester) async {
    final page = await openPage(tester);
    await scrollTo(tester, find.text('保留天数'));
    // 没有保存过设置时按默认 14 天显示。
    expect(find.text('14 天'), findsOneWidget);

    final select = find.byKey(const ValueKey('data-version-retention-days'));
    await tester.tap(
      find
          .descendant(of: select, matching: find.byType(forui.FTextField))
          .first,
    );
    await tester.pumpAndSettle();
    final option = find.ancestor(
      of: find.text('30 天'),
      matching: find.byWidgetPredicate((widget) => widget is forui.FSelectItem),
    );
    await tester.tap(option.last);
    await settle(tester);
    expect(find.text('30 天'), findsOneWidget);

    // 设置保存成一条提交，自动裁剪与手动裁剪读同一个值。
    final saved = await tester.runAsync(
      () => page.scope.settings.edit.revisionRetentionDays(),
    );
    expect(saved, 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按留存清理的确认写清保留天数与窗口', (tester) async {
    await openPage(tester);
    await scrollTo(tester, find.text('按留存清理'));
    await tester.tap(find.text('按留存清理'));
    await settle(tester);
    expect(find.textContaining('最近 14 天'), findsOneWidget);
    expect(find.textContaining('超出预算时从最早的开始删'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销提交提供重做：确认写清会发生什么，重做后原提交重新可撤销', (tester) async {
    final appScope = (await openPage(tester)).scope;
    await tester.runAsync(
      () => insertRow(appScope.testing.db, 'memory', {
        'id': 'memory-1',
        'kind': 'semantic',
        'content': '原来记下的内容',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
    );
    await tester.runAsync(
      () => updateRow(
        appScope.testing.db,
        'memory',
        {'content': '改过的内容'},
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
    );
    final history = await tester.runAsync(
      () => appScope.data.revisions.history(),
    );
    final edit = history!.head;
    final undone = await tester.runAsync(
      () => appScope.data.undo.undoCommit(edit),
    );
    expect(undone!.applied, isTrue, reason: undone.message);
    await settle(tester);

    // 撤销提交是 HEAD：标签说“撤销”，菜单给的是“重做”，不再按普通撤销处理。
    await tester.scrollUntilVisible(
      find.text('撤销（HEAD）'),
      300,
      scrollable: pageScrollable(),
    );
    await settle(tester);
    expect(find.text('撤销（HEAD）'), findsOneWidget);
    final undoCommitTile = find.ancestor(
      of: find.text('撤销（HEAD）'),
      matching: find.byType(forui.FTile),
    );
    await tester.tap(
      find.descendant(
        of: undoCommitTile,
        matching: find.byIcon(FLucideIcons.ellipsis),
      ),
    );
    await settle(tester);
    expect(find.text('重做这次撤销'), findsOneWidget);
    expect(find.text('撤销这次操作'), findsNothing);

    // 确认框说清会写回被撤销的内容，消息里的回执不恢复。
    await tester.tap(find.text('重做这次撤销'));
    await settle(tester);
    expect(find.text('重做这次撤销'), findsOneWidget);
    expect(find.textContaining('会把这条撤销去掉的内容按原来的样子重新写入'), findsOneWidget);
    expect(find.textContaining('消息里的回执不会恢复'), findsOneWidget);
    await tester.tap(find.text('重做'));
    await settle(tester);

    expect(find.text('已重做这次撤销'), findsOneWidget);
    final content = await tester.runAsync(
      () => appScope.testing.db.rawQuery(
        'SELECT content FROM memory WHERE id = ?',
        ['memory-1'],
      ),
    );
    expect(content!.single['content'], '改过的内容');
    // 重做提交按层数显示“重做”，原来那次写入重新可以撤销。
    expect(find.text('重做（HEAD）'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('写入').first,
      300,
      scrollable: pageScrollable(),
    );
    await settle(tester);
    final writeTile = find.ancestor(
      of: find.text('写入').first,
      matching: find.byType(forui.FTile),
    );
    await tester.tap(
      find.descendant(
        of: writeTile,
        matching: find.byIcon(FLucideIcons.ellipsis),
      ),
    );
    await settle(tester);
    final undoItems = tester.widgetList<forui.FTile>(
      find.ancestor(
        of: find.text('撤销这次操作'),
        matching: find.byType(forui.FTile),
      ),
    );
    expect(undoItems.any((item) => item.enabled ?? true), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('明细里的记忆类型与状态显示中文，旧四类与已替换不再出现', (tester) async {
    final appScope = (await openPage(tester)).scope;
    await tester.runAsync(() async {
      await appScope.testing.tasks.createGoal(title: '明细取值目标');
      final head = await appScope.testing.db
          .rawQuery(
            'SELECT head_commit_id AS id FROM revision_state WHERE id = 1',
          )
          .then((rows) => rows.single['id']! as int);
      await appScope.data.revisions.applyRemoteCommit(
        uid: 'remote-memory-labels-1',
        action: '其他设备写入记忆',
        actor: 'ai',
        kind: RevisionKind.write,
        changes: [
          RevisionChange(
            commitId: head,
            seq: 0,
            table: 'memory',
            rowKey: 'memory-labels-1',
            op: ChangeOp.insert,
            after: typedRow({
              'id': 'memory-labels-1',
              'kind': 'semantic',
              'content': '线性代数是本学期的必修课',
              'scope': null,
              'source_kind': 'user',
              'source_id': null,
              'valid_until': null,
              'search_terms': '',
              'reviewed_at': null,
              'status': 'active',
              'created_at': '2026-11-20 09:00:00',
              'updated_at': '2026-11-20 09:00:00',
            }),
          ),
        ],
      );
    });
    await settle(tester);

    final remoteTile = find.ancestor(
      of: find.text('写入（HEAD）'),
      matching: find.byType(forui.FTile),
    );
    await scrollTo(tester, remoteTile);
    await tester.tap(
      find.descendant(
        of: remoteTile,
        matching: find.byIcon(FLucideIcons.ellipsis),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('查看明细'));
    await settle(tester);
    expect(find.text('记忆 · 新增'), findsOneWidget);
    expect(find.textContaining('类型：语义'), findsOneWidget);
    expect(find.textContaining('状态：有效'), findsOneWidget);
    expect(find.textContaining('偏好'), findsNothing);
    expect(find.textContaining('已替换'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(ThemeModeController themeMode, RevisionService? revisions) {
  return MaterialApp(
    title: '知新',
    debugShowCheckedModeBanner: false,
    theme: zhixinTheme,
    darkTheme: zhixinDarkTheme,
    themeMode: ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: const [
      ...GlobalMaterialLocalizations.delegates,
      forui.FLocalizations.delegate,
    ],
    builder: (context, child) => forui.FTheme(
      data: zhixinForuiTheme,
      child: forui.FToaster(
        style: zhixinToasterStyle,
        child: AppScope(
          themeAccent: ThemeAccentController(),
          themeMode: themeMode,
          child: child!,
        ),
      ),
    ),
    home: DataVersionPage(revisions: revisions),
  );
}

/// 一处被远端覆盖的讨论标题：本机原来的值与远端应用后的值不同。
RevisionConflict _titleConflict() => RevisionConflict(
  id: 7,
  commitId: 9,
  table: 'conversation',
  rowKey: 'conv-1',
  column: 'title',
  reason: RevisionConflict.concurrentUpdate,
  local: typedRow({'title': '本机原来的标题'}),
  remoteBefore: typedRow({'title': '两边开始时的标题'}),
  remoteAfter: typedRow({'title': '其他设备改后的标题'}),
);

/// 本机删掉了这一行、远端还在改它：没有可以写回的本机值。
RevisionConflict _deletedLocallyConflict() => RevisionConflict(
  id: 8,
  commitId: 10,
  table: 'conversation',
  rowKey: 'conv-2',
  column: 'title',
  reason: RevisionConflict.deletedLocally,
  local: typedRow({'title': '其他设备改后的标题'}),
  remoteBefore: typedRow({'title': '两边开始时的标题'}),
  remoteAfter: typedRow({'title': '其他设备改后的标题'}),
);

/// 版本服务替身：只改同步冲突、清理阻塞、完整性检查与写回本机值这几处读取。
class _StubRevisions extends RevisionService {
  _StubRevisions(
    TestRig rig, {
    List<RevisionConflict> pendingConflicts = const [],
    this.blockers = const [],
    this.integrityProblems = const [],
  }) : pendingConflicts = List.of(pendingConflicts),
       super(
         db: rig.db,
         raw: () => rig.raw,
         engine: rig.engine,
         clock: systemClock,
         cache: AttachmentCache(filesDir: () => rig.filesDir),
       );

  List<RevisionConflict> pendingConflicts;
  final List<String> blockers;

  /// 完整性检查报出的问题；为空表示通过。附件核对项在这里恒通过。
  final List<String> integrityProblems;
  final List<bool> blockerRequests = [];
  int? keptConflictId;
  int? dismissedConflictId;

  @override
  Future<RevisionIntegrityReport> verifyIntegrity() async =>
      RevisionIntegrityReport(
        commitId: 12,
        checkedCommits: 13,
        problems: integrityProblems,
      );

  @override
  Future<List<String>> verifyAssets() async => const [];

  @override
  Future<bool> dismissConflict(int conflictId) async {
    dismissedConflictId = conflictId;
    pendingConflicts = const [];
    return true;
  }

  @override
  Future<List<RevisionConflict>> conflicts({bool unresolved = true}) async =>
      pendingConflicts;

  @override
  Future<List<String>> historyBlockers({bool clearing = false}) async {
    blockerRequests.add(clearing);
    return blockers;
  }

  @override
  Future<RevisionCommit?> keepLocal(int conflictId) async {
    keptConflictId = conflictId;
    pendingConflicts = const [];
    return RevisionCommit(
      id: 42,
      uid: '0190a5b3-8f2c-7a41-b0c6-5d1e2f3a4b5c',
      parentId: 41,
      generation: 1,
      actor: 'system',
      action: '保留本机修改',
      kind: RevisionKind.write,
      changeCount: 1,
      createdAt: DateTime(2026, 11, 20, 10),
    );
  }
}
