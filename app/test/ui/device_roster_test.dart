// ADR-0048 的界面验收用例：设备名册、别名显示与改名。
//
// 应用根照生产装配，只把服务端换成进程内的假服务端；先登录再推入页面，页面首读
// 就能拿到登录状态与设备名册。覆盖：
// - 账号页“设备”一节显示别名、未命名设备、标识前 8 位、最近出现时间与本机标记；
// - 改名弹窗写入之后列表立即显示新别名；
// - 数据版本页的远端提交来源优先显示别名，没有别名时仍是前 8 位。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/ui/account_page.dart';
import 'package:zhixin/ui/data_version_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';
import 'package:zhixin/ui/workspace_widgets.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const serverUrl = 'http://server.test';
  const email = 'devices@example.com';
  const password = 'password123';
  late Directory directory;
  late Map<String, String> secrets;
  late FakeServer server;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-device-roster-');
    await disableTelemetryForTests(directory.path);
    secrets = {};
    server = FakeServer();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    // 登录会话要能在页面之间读回来，安全存储按 Map 保存。
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

  Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var round = 0; round < 100; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  Finder pageScrollable(Type page) => find
      .descendant(of: find.byType(page), matching: find.byType(Scrollable))
      .first;

  /// 等页面打开时发起的名册读取完成：真实文件与假服务端的往返在测试的假异步区
  /// 里要分几轮才走完，固定次数的 pump 不够。
  Future<void> waitForDevices(WidgetTester tester) async {
    for (var round = 0; round < 100; round++) {
      if (scope!.accountServices.sync.devices.isNotEmpty) {
        await settle(tester);
        return;
      }
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    fail('等待设备名册超时');
  }

  /// 装应用根、登录、按用例准备好名册，再推入 [page]；页面首读走同一份服务。
  Future<void> openPage(
    WidgetTester tester, {
    required Widget page,
    required Future<void> Function(AppScopeState appScope, String userId)
    prepare,
  }) async {
    tester.view.physicalSize = const Size(390, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final themeMode = ThemeModeController();
    addTearDown(themeMode.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          title: '知新',
          debugShowCheckedModeBanner: false,
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
              style: zhixinToasterStyle,
              child: AppScope(
                themeMode: themeMode,
                serverClientFactory: (baseUrl) =>
                    ServerClient(baseUrl: baseUrl, httpClient: server.client),
                child: child!,
              ),
            ),
          ),
          home: const SizedBox.shrink(),
        ),
      );
      final appScope = tester.state<AppScopeState>(find.byType(AppScope));
      await appScope.ready;
      await appScope.accountServices.account.setServerBaseUrl(serverUrl);
      await appScope.accountServices.account.register(
        identifier: email,
        password: password,
      );
      await prepare(appScope, server.userIdOf(email));
      scope = appScope;
    });
    await tester.pump();
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
    await settle(tester);
  }

  testWidgets('账号页设备一节显示别名、标识前 8 位、最近出现时间与本机标记', (tester) async {
    await openPage(
      tester,
      page: const AccountPage(),
      prepare: (appScope, userId) async {
        final local = await appScope.accountServices.account.deviceId();
        server.putDevice(
          userId,
          deviceId: local,
          lastSeen: '2026-11-20T09:00:00Z',
        );
        server.putDevice(
          userId,
          deviceId: 'device-other-12345678',
          alias: '小明的手机',
          lastSeen: '2026-11-22T10:00:00Z',
        );
      },
    );
    await waitFor(tester, find.text('小明的手机'));

    expect(find.widgetWithText(SectionHeading, '设备'), findsOneWidget);
    expect(find.text('小明的手机'), findsOneWidget);
    expect(find.text('未命名设备'), findsOneWidget, reason: '本机还没有别名');
    expect(find.text('本机'), findsOneWidget, reason: '只有本机这一行带标记');
    expect(
      find.textContaining('device-o'),
      findsOneWidget,
      reason: '列表里显示另一台设备标识的前 8 位',
    );
    expect(
      find.text('device-other-12345678'),
      findsNothing,
      reason: '整串设备标识不上界面',
    );
    expect(find.textContaining('最近出现'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('改名弹窗写入之后设备列表立即显示新别名', (tester) async {
    await openPage(
      tester,
      page: const AccountPage(),
      prepare: (appScope, userId) async {
        final local = await appScope.accountServices.account.deviceId();
        server.putDevice(
          userId,
          deviceId: local,
          lastSeen: '2026-11-20T09:00:00Z',
        );
        server.putDevice(
          userId,
          deviceId: 'device-other-12345678',
          alias: '小明的手机',
          lastSeen: '2026-11-22T10:00:00Z',
        );
      },
    );
    await waitFor(tester, find.text('小明的手机'));

    // 名册按最近出现时间倒序，另一台设备排在前面，它的“改名”是第一个。
    await tester.tap(find.text('改名').first);
    await settle(tester);
    expect(find.text('设备改名'), findsOneWidget);
    expect(find.textContaining('别名用来在提交来源'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).last, '小明的备用手机');
    await tester.tap(find.text('保存'));
    await settle(tester);
    await waitFor(tester, find.text('小明的备用手机'));

    expect(find.text('小明的备用手机'), findsOneWidget);
    expect(find.text('小明的手机'), findsNothing, reason: '旧别名被新别名替换');
    expect(
      server
          .rosterOf(server.userIdOf(email))
          .firstWhere((device) => device.deviceId == 'device-other-12345678')
          .alias,
      '小明的备用手机',
    );
    expect(find.textContaining('已把设备名改为'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页的提交来源优先显示别名', (tester) async {
    await openPage(
      tester,
      page: const DataVersionPage(),
      prepare: (appScope, userId) async {
        server.putDevice(
          userId,
          deviceId: 'device-other-12345678',
          alias: '小明的手机',
          lastSeen: '2026-11-22T10:00:00Z',
        );
        await applyRemoteCommit(appScope, deviceId: 'device-other-12345678');
      },
    );

    final source = find.textContaining('来自另一台设备 小明的手机');
    await waitForDevices(tester);
    await tester.scrollUntilVisible(
      source,
      300,
      scrollable: pageScrollable(DataVersionPage),
    );
    await waitFor(tester, source);
    expect(source, findsOneWidget);
    expect(
      find.textContaining('device-other-12345678'),
      findsNothing,
      reason: '有别名时不再显示标识',
    );
    expect(find.textContaining('来自另一台设备 device-o'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据版本页没有别名时仍然显示标识前 8 位', (tester) async {
    await openPage(
      tester,
      page: const DataVersionPage(),
      prepare: (appScope, userId) async {
        await applyRemoteCommit(appScope, deviceId: 'device-unknown-abcdef');
      },
    );

    final source = find.textContaining('来自另一台设备 device-u');
    await waitForDevices(tester);
    await tester.scrollUntilVisible(
      source,
      300,
      scrollable: pageScrollable(DataVersionPage),
    );
    await waitFor(tester, source);
    expect(source, findsOneWidget);
    expect(
      find.textContaining('device-unknown-abcdef'),
      findsNothing,
      reason: '没有别名时只显示前 8 位，整串标识不上界面',
    );
    expect(tester.takeException(), isNull);
  });
}

/// 在应用根上追加一条远端提交：来源设备用来核对别名显示。
Future<void> applyRemoteCommit(
  AppScopeState appScope, {
  required String deviceId,
}) {
  return appScope.data.revisions.applyRemoteCommit(
    uid: 'remote-$deviceId',
    action: '其他设备新增讨论',
    actor: 'system',
    originDevice: deviceId,
    authoredAt: DateTime(2026, 11, 20, 9, 30),
    changes: [
      RevisionChange(
        commitId: 0,
        seq: 0,
        table: 'conversation',
        rowKey: 'conv-$deviceId',
        op: ChangeOp.insert,
        after: typedRow({
          'id': 'conv-$deviceId',
          'title': '其他设备追加的讨论',
          'entry_kind': 'text',
          'status': 'open',
          'created_at': '2026-11-20 09:00:00',
          'updated_at': '2026-11-20 09:00:00',
        }),
      ),
    ],
  );
}
