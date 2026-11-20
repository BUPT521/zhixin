import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/data/revisions/revision_service.dart';
import 'package:zhixin/domain/rules/time_policy.dart';
import 'package:zhixin/ui/data_version_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
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
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
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

    // 清理历史读的是另一组阻塞原因（clearing: true）。
    await scrollTo(tester, find.text('清理历史'));
    await tester.tap(find.text('清理历史'));
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

    // 远端提交：动作文案由数据层记录，标签按 kind 显示成“其他设备”。
    await tester.runAsync(
      () => appScope.data.revisions.applyRemoteCommit(
        uid: 'remote-lane-v-1',
        action: '其他设备新增讨论',
        actor: 'system',
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
              'status': 'open',
              'created_at': '2026-11-20 09:00:00',
              'updated_at': '2026-11-20 09:00:00',
            }),
          ),
        ],
      ),
    );
    await settle(tester);

    expect(find.text('其他设备（HEAD）'), findsOneWidget);
    expect(find.text('写入'), findsOneWidget);
    expect(find.textContaining('其他设备新增讨论'), findsOneWidget);
    expect(find.byIcon(FLucideIcons.cloudDownload), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除命名版本与清理历史都先弹确认，命名版本说明写清清理时保留', (tester) async {
    final appScope = (await openPage(tester)).scope;
    await tester.runAsync(
      () async => appScope.data.revisions.name(
        await appScope.data.versions.currentHead(),
        label: '版本一',
      ),
    );
    await settle(tester);

    await scrollTo(tester, find.text('版本一'));
    expect(find.textContaining('命名后在清理历史时保留'), findsOneWidget);

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

    // 清理历史：同样先确认，取消之后历史仍在。
    await scrollTo(tester, find.text('清理历史'));
    await tester.tap(find.text('清理历史'));
    await settle(tester);
    expect(find.text('清理历史'), findsNWidgets(2));
    expect(find.text('清理'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('提交历史'), findsOneWidget);
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
        child: AppScope(themeMode: themeMode, child: child!),
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

/// 版本服务替身：只改同步冲突、清理阻塞与写回本机值这三处读取。
class _StubRevisions extends RevisionService {
  _StubRevisions(
    TestRig rig, {
    List<RevisionConflict> pendingConflicts = const [],
    this.blockers = const [],
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
  final List<bool> blockerRequests = [];
  int? keptConflictId;
  int? dismissedConflictId;

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
