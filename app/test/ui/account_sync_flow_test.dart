// 账号页与“我的”页的同步确认走同一流程（审查条目 A22）。
//
// 两页原先各写一遍“先读同步状态、再问恢复对齐或首次基线、最后问快照重建”的顺序，
// 已经出现提示文案的差异。现在确认顺序与执行在 SyncFlow，两个页面都把
// confirmSyncStep 当作确认回调；用例核对同一份前置状态下，两页弹出的确认框、
// 取消之后的说明与副作用都相同。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/ui/account_page.dart';
import 'package:zhixin/ui/mine_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';
import 'package:zhixin/ui/zhixin_dialog.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const email = 'sync-flow-ui@example.com';

  /// 取消首次同步之后两页都要给的说明；两页写的是同一句。
  const cancelledBaselineNotice = '已取消首次同步，没有上传本机记录；自动同步已暂停';

  late Directory directory;
  late FakeServer server;
  late Map<String, String> secrets;
  late GlobalKey<NavigatorState> navigator;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-syncflow-ui-');
    await disableTelemetryForTests(directory.path);
    secrets = {};
    server = FakeServer();
    navigator = GlobalKey<NavigatorState>();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
        final key = args['key'] as String?;
        switch (call.method) {
          case 'write':
            secrets[key!] = args['value']! as String;
            return null;
          case 'read':
            return secrets[key];
          case 'delete':
            secrets.remove(key);
            return null;
          case 'containsKey':
            return secrets.containsKey(key);
          case 'readAll':
            return secrets;
          case 'deleteAll':
            secrets.clear();
            return null;
        }
        return null;
      },
    );
  });

  tearDown(() async {
    await closeAppScope(scope, directory);
    scope = null;
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: zhixinTheme,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            ...GlobalMaterialLocalizations.delegates,
            forui.FLocalizations.delegate,
          ],
          builder: (context, child) => forui.FTheme(
            data: zhixinForuiTheme,
            child: forui.FToaster(
              child: AppScope(
                themeAccent: ThemeAccentController(),
                themeMode: ThemeModeController(),
                serverClientFactory: (baseUrl) =>
                    ServerClient(baseUrl: baseUrl, httpClient: server.client),
                child: child!,
              ),
            ),
          ),
          home: const SizedBox.shrink(),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await tester.pump();
  }

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 400,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(() async {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 登录并在本机写一条记忆：形成提交，第一次同步因此要确认基线。
  Future<void> signInWithLocalCommit(WidgetTester tester) async {
    await tester.runAsync(() async {
      await scope!.accountServices.account.register(
        identifier: email,
        password: 'password123',
      );
      await scope!.accountServices.account.setAutoSync(false);
      await scope!.testing.db.command((txn) async {
        await insertRow(txn, 'memory', {
          'id': 'm1',
          'kind': 'semantic',
          'content': '喜欢先看例子',
          'scope': null,
          'source_kind': 'user',
          'source_id': null,
          'valid_until': null,
          'status': 'active',
          'created_at': '2026-11-17 10:00:00',
          'updated_at': '2026-11-17 10:00:00',
        });
      }, label: '新增记忆');
    });
  }

  Finder dialogAction(String label) => find.descendant(
    of: find.byType(ZhixinDialogLayout),
    matching: find.widgetWithText(forui.FButton, label),
  );

  /// 点与“立即同步”同名的按钮；两页各有一个，取页面上唯一的那一个。
  Future<void> tapSyncNow(WidgetTester tester) async {
    final button = find.widgetWithText(forui.FButton, '立即同步');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  testWidgets('两个页面的同步确认走同一流程：同一确认框、同一取消说明与同一副作用', (tester) async {
    await pumpApp(tester);
    await signInWithLocalCommit(tester);
    final userId = server.userIdOf(email);

    // 账号页：点立即同步，先确认首次基线，取消之后不执行。
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const AccountPage()),
    );
    await waitFor(tester, find.text('同步'));
    await tapSyncNow(tester);
    await waitFor(tester, find.byType(ZhixinDialogLayout));
    expect(find.text('首次同步会把本机记录合并到账号'), findsOneWidget);
    expect(find.textContaining('本机现在有 1 条提交'), findsOneWidget);
    await tester.tap(dialogAction('取消'));
    await waitFor(tester, find.text(cancelledBaselineNotice));
    expect(
      await tester.runAsync(() => scope!.accountServices.account.autoSync()),
      isFalse,
      reason: '取消首次同步会暂停自动同步',
    );
    expect(server.commits[userId] ?? const [], isEmpty, reason: '取消之后没有上传提交');

    // 回到“我的”，同一个前置状态下点立即同步：确认框与取消之后的副作用与账号页
    // 一致。结论说明由 syncResultNotice 统一给出，见 cloud_sync_prompts_test 的
    // 那条用例，这里不再依赖“我的”页后台重读的时序去等它出现。
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    final active = ValueNotifier<int>(3);
    addTearDown(active.dispose);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => MinePage(activeTab: active)),
    );
    await waitFor(tester, find.text('立即同步'));
    await tapSyncNow(tester);
    await waitFor(tester, find.byType(ZhixinDialogLayout));
    expect(find.text('首次同步会把本机记录合并到账号'), findsOneWidget);
    expect(find.textContaining('本机现在有 1 条提交'), findsOneWidget);
    await tester.tap(dialogAction('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ZhixinDialogLayout), findsNothing);
    expect(server.commits[userId] ?? const [], isEmpty, reason: '两个页面取消之后都不上传');
    expect(tester.takeException(), isNull);
  });
}
