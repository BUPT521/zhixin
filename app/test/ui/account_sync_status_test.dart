// 账号页与“我的”页在整库摘要不一致时的界面口径（ADR-0045、02 第 3.16 节）。
//
// 前置状态用真同步造出来，不直接改同步状态：先让本机推送一份带摘要的基线，
// 另一台设备拉取之后再加一条记录推上去，最后让这台设备漏掉一条自己已经推送过
// 的记录（绕过命令事务直接改库，不形成提交），下一次拉取比较整库摘要时就会
// 发现不一致，写进这个身份的同步状态。与 `test/application/sync_digest_test.dart`
// 的造法一致，只是这台设备是 AppScope 里的库，所以“绕过命令事务”走
// `selectGenerated` 里的原始语句：采集只在命令事务里打开，事务之外写库不会形成
// 提交，也不会被版本引擎记下来。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/sync_service.dart';
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
import '../support/sync_rig.dart';
import '../support/telemetry.dart';
import '../support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const email = 'sync-ui@example.com';

  late Directory directory;
  late FakeServer server;
  late Map<String, String> secrets;
  late GlobalKey<NavigatorState> navigator;
  late TestClock clock;
  AppScopeState? scope;
  final devices = <SyncDevice>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-sync-ui-');
    await disableTelemetryForTests(directory.path);
    secrets = {};
    server = FakeServer();
    navigator = GlobalKey<NavigatorState>();
    clock = TestClock();
    devices.clear();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    // 会话写在安全存储里：页面重建与再次读取都要读得回来。
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
    for (final device in devices) {
      await device.close();
    }
    await closeAppScope(scope, directory);
    scope = null;
  });

  /// 装上应用根，等首读完成；页面通过路由推进去，与真实应用的层级一致。
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

  /// 等界面出现某个文字；页面首读要过数据库与假服务端，按现有用例的写法轮询。
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 150,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 这台设备登录同一个账号；自动同步关掉，用例自己决定什么时候同步。
  Future<void> signInThisDevice(WidgetTester tester) async {
    await tester.runAsync(() async {
      await scope!.accountServices.account.register(
        identifier: email,
        password: syncTestPassword,
      );
      await scope!.accountServices.account.setAutoSync(false);
    });
  }

  /// 经过命令事务写一条记忆：形成提交，会随同步推上去。
  Future<void> insertThisDeviceMemory(
    WidgetTester tester,
    String id,
    String content,
  ) async {
    await tester.runAsync(
      () => scope!.testing.db.command((txn) async {
        await insertRow(txn, 'memory', {
          'id': id,
          'kind': 'semantic',
          'content': content,
          'scope': null,
          'source_kind': 'user',
          'source_id': null,
          'valid_until': null,
          'status': 'active',
          'created_at': '2026-11-17 10:00:00',
          'updated_at': '2026-11-17 10:00:00',
        });
      }, label: '新增记忆'),
    );
  }

  /// 直接改库、不形成提交：模拟一次没有到达云端、也没有留下提交记录的丢写。
  ///
  /// 采集只在命令事务里打开，这里走的是 `selectGenerated` 里的原始语句，绕开了
  /// 命令事务的采集，与 `sync_digest_test.dart` 里直接改 rig 的库等价。
  Future<void> deleteThisDeviceMemoryWithoutCommit(
    WidgetTester tester,
    String id,
  ) async {
    await tester.runAsync(
      () => scope!.testing.db.selectGenerated(
        (db) => db.customStatement('DELETE FROM memory WHERE id = ?', [id]),
      ),
    );
  }

  /// 直接插一行、不形成提交：模拟本机独有、云端还没有的记录。
  Future<void> insertThisDeviceMemoryWithoutCommit(
    WidgetTester tester,
    String id,
    String content,
  ) async {
    await tester.runAsync(
      () => scope!.testing.db.selectGenerated(
        (db) => db.customStatement(
          'INSERT INTO memory (id, kind, content, scope, source_kind, '
          'source_id, valid_until, status, created_at, updated_at) '
          "VALUES (?, 'semantic', ?, NULL, 'user', NULL, NULL, 'active', "
          "'2026-11-17 10:00:00', '2026-11-17 10:00:00')",
          [id, content],
        ),
      ),
    );
  }

  Future<void> syncThisDevice(
    WidgetTester tester, {
    bool confirmBaseline = false,
  }) async {
    await tester.runAsync(
      () =>
          scope!.accountServices.sync.syncNow(confirmBaseline: confirmBaseline),
    );
  }

  /// 另一台登录同一个账号的设备；登录时它没有本机提交，首次同步只拉取。
  Future<SyncDevice> openPeerDevice(WidgetTester tester) async {
    late SyncDevice device;
    await tester.runAsync(() async {
      device = await openSyncDevice(
        server,
        rig: await openTestRig(clock: clock.call),
        email: email,
        register: false,
        deviceId: 'device-peer',
        clock: clock,
      );
    });
    devices.add(device);
    return device;
  }

  Future<void> openAccountPage(WidgetTester tester) async {
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const AccountPage()),
    );
    await waitFor(tester, find.text('同步'));
  }

  Finder cloudRepairButton() => find.widgetWithText(forui.FButton, '以云端为准修复');
  Finder localRepairButton() => find.widgetWithText(forui.FButton, '以本机为准修复');

  Finder dialogAction(String label) => find.descendant(
    of: find.byType(ZhixinDialogLayout),
    matching: find.widgetWithText(forui.FButton, label),
  );

  /// 这台设备漏掉一条自己已经推上去的记录：云端有、本机没有。
  ///
  /// 另一台设备拉到基线之后再加一条、带着新摘要推上去；这台设备删掉本机那一行
  /// （没有形成提交）之后同步，拉到带摘要的提交时比较出不一致。
  Future<void> seedCloudAheadMismatch(WidgetTester tester) async {
    await signInThisDevice(tester);
    await insertThisDeviceMemory(tester, 'm1', '喜欢先看例子');
    await syncThisDevice(tester, confirmBaseline: true);

    final peer = await openPeerDevice(tester);
    await tester.runAsync(() async {
      await peer.sync.syncNow();
      await insertTestMemory(peer.rig, 'm2', content: '晚上效率低');
      await peer.sync.syncNow();
    });
    await deleteThisDeviceMemoryWithoutCommit(tester, 'm1');
    await syncThisDevice(tester);

    final status = await tester.runAsync(
      () => scope!.accountServices.sync.status(),
    );
    expect(status!.digestMismatch, isTrue, reason: '前置状态：整库摘要已经不一致');
  }

  /// 这台设备多一条云端没有的记录：直接写库，没有形成提交。
  ///
  /// 另一台设备推一条新提交，这台设备拉取时比较摘要，发现本机多出来的那一行。
  Future<void> seedLocalOnlyMismatch(WidgetTester tester) async {
    await signInThisDevice(tester);
    await insertThisDeviceMemory(tester, 'm1', '喜欢先看例子');
    await syncThisDevice(tester, confirmBaseline: true);
    await insertThisDeviceMemoryWithoutCommit(tester, 'm2', '本机独有的记录');

    final peer = await openPeerDevice(tester);
    await tester.runAsync(() async {
      await peer.sync.syncNow();
      await insertTestMemory(peer.rig, 'm3', content: '云端新加的一行');
      await peer.sync.syncNow();
    });
    await syncThisDevice(tester);

    final status = await tester.runAsync(
      () => scope!.accountServices.sync.status(),
    );
    expect(status!.digestMismatch, isTrue, reason: '前置状态：整库摘要已经不一致');
  }

  /// 两台设备内容相同、摘要一致：拉取带摘要的提交之后比较通过。
  Future<void> seedMatched(WidgetTester tester) async {
    await signInThisDevice(tester);
    await insertThisDeviceMemory(tester, 'm1', '喜欢先看例子');
    await syncThisDevice(tester, confirmBaseline: true);

    final peer = await openPeerDevice(tester);
    await tester.runAsync(() async {
      await peer.sync.syncNow();
      await insertTestMemory(peer.rig, 'm2', content: '晚上效率低');
      await peer.sync.syncNow();
    });
    await syncThisDevice(tester);

    final status = await tester.runAsync(
      () => scope!.accountServices.sync.status(),
    );
    expect(status!.digestMismatch, isFalse, reason: '前置状态：两边摘要一致');
  }

  /// 打开“我的”；账号卡加载完之后标签才在树里。
  Future<void> openMinePage(WidgetTester tester) async {
    final active = ValueNotifier<int>(3);
    addTearDown(active.dispose);
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => MinePage(activeTab: active)),
    );
    await waitFor(tester, find.byType(MinePage));
  }

  testWidgets('摘要不一致时账号页的同步卡显示待修复、说明与两个可点修复入口', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);

    await openAccountPage(tester);
    await waitFor(tester, find.text('待修复'));

    expect(find.text('待修复'), findsOneWidget);
    expect(find.text('本机与云端不一致'), findsOneWidget);
    expect(find.textContaining('上次同步比较整库摘要时发现两边内容不同'), findsOneWidget);
    expect(find.textContaining('以云端为准会按云端重新对齐这台设备'), findsOneWidget);
    expect(find.textContaining('以本机为准会把云端缺少的本机记录补传上去'), findsOneWidget);
    expect(cloudRepairButton(), findsOneWidget);
    expect(localRepairButton(), findsOneWidget);
    expect(
      tester.widget<forui.FButton>(cloudRepairButton()).onPress,
      isNotNull,
    );
    expect(
      tester.widget<forui.FButton>(localRepairButton()).onPress,
      isNotNull,
    );

    // 状态卡与说明不能互相矛盾：卡上是“待修复”，就不能说两边已经一致。
    expect(find.textContaining('已经一致'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('以云端为准修复：取消不做修复，确认之后给出结果并回到空闲', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);
    await openAccountPage(tester);
    await waitFor(tester, find.text('待修复'));
    final userId = server.userIdOf(email);
    final headBefore = server.headOf(userId);

    // 取消：确认框说明会改哪一边，退出之后不做修复，卡片保持原样。
    await tester.tap(cloudRepairButton());
    await waitFor(tester, find.text('以云端为准修复会重做这台设备的同步'));
    expect(find.textContaining('重新从云端拉取全部提交'), findsOneWidget);
    expect(find.textContaining('云端已有的记录不会删除'), findsOneWidget);
    expect(find.textContaining('取消则不做修复，两边内容保持原样'), findsOneWidget);
    await tester.tap(dialogAction('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ZhixinDialogLayout), findsNothing);
    expect(find.text('待修复'), findsOneWidget);
    expect(find.text('本机与云端不一致'), findsOneWidget);
    expect(find.textContaining('已按云端修复'), findsNothing);
    expect(server.headOf(userId), headBefore, reason: '取消不执行修复，云端序列不变');

    // 确认之后修复执行；修复途中页面 busy，两个入口都不可点。
    final gate = Completer<void>();
    server.onPull = () => gate.future;
    await tester.tap(cloudRepairButton());
    await waitFor(tester, find.text('以云端为准修复会重做这台设备的同步'));
    await tester.tap(dialogAction('以云端为准修复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ZhixinDialogLayout), findsNothing);
    expect(find.text('待修复'), findsOneWidget);
    expect(tester.widget<forui.FButton>(cloudRepairButton()).onPress, isNull);
    expect(tester.widget<forui.FButton>(localRepairButton()).onPress, isNull);

    server.onPull = null;
    await tester.runAsync(() async {
      gate.complete();
    });
    await waitFor(tester, find.textContaining('已按云端修复'));
    // 结果提示先出现，页面随后重读同步状态；等到状态卡换掉再一起核对。
    await waitFor(tester, find.text('空闲'));
    expect(find.textContaining('本机与云端重新对齐'), findsOneWidget);
    expect(find.text('待修复'), findsNothing);
    expect(cloudRepairButton(), findsNothing);
    expect(localRepairButton(), findsNothing);
    expect(server.headOf(userId), headBefore, reason: '以云端为准不新增云端内容');
    expect(tester.takeException(), isNull);
  });

  testWidgets('以本机为准修复：取消不做修复，确认之后补传并回到空闲', (tester) async {
    await pumpApp(tester);
    await seedLocalOnlyMismatch(tester);
    await openAccountPage(tester);
    await waitFor(tester, find.text('待修复'));
    final userId = server.userIdOf(email);
    final headBefore = server.headOf(userId);

    // 取消：这个入口只补传、不删除云端已有的记录，确认框要写清楚。
    await tester.tap(localRepairButton());
    await waitFor(tester, find.text('以本机为准修复会补传云端缺少的记录'));
    expect(find.textContaining('云端已有的记录不会删除'), findsOneWidget);
    expect(find.textContaining('取消则不做修复'), findsOneWidget);
    await tester.tap(dialogAction('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ZhixinDialogLayout), findsNothing);
    expect(find.text('待修复'), findsOneWidget);
    expect(find.textContaining('已按本机修复'), findsNothing);
    expect(server.headOf(userId), headBefore, reason: '取消不执行修复，云端序列不变');

    // 确认之后补传本机独有的那一行。
    await tester.tap(localRepairButton());
    await waitFor(tester, find.text('以本机为准修复会补传云端缺少的记录'));
    await tester.tap(dialogAction('以本机为准修复'));
    await waitFor(tester, find.textContaining('已按本机修复'));
    // 结果提示先出现，页面随后重读同步状态；等到状态卡换掉再一起核对。
    await waitFor(tester, find.text('空闲'));
    expect(find.textContaining('云端缺少的本机记录已经上传'), findsOneWidget);
    expect(find.text('待修复'), findsNothing);
    expect(cloudRepairButton(), findsNothing);
    expect(localRepairButton(), findsNothing);
    expect(
      server.headOf(userId),
      headBefore + 1,
      reason: '本机独有的 m2 作为一条基线提交补传，云端已有内容不删除',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('摘要不一致时点立即同步，结论说明仍不一致，不声称已经一致', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);
    await openAccountPage(tester);
    await waitFor(tester, find.text('待修复'));

    await tester.tap(find.widgetWithText(forui.FButton, '立即同步'));
    await waitFor(tester, find.textContaining('同步完成；本机与云端的内容仍不一致'));
    // 结果提示里也会重读状态；等到标签仍是“待修复”时再核对文案。
    await tester.pump();

    // 卡上还是“待修复”，提示就不能说“已经一致”。
    expect(find.text('待修复'), findsOneWidget);
    expect(find.textContaining('已经一致'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步中账号页的两个修复入口都不可点', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);

    // 把这一轮同步停在拉取上：页面读到 syncing 为真，标签应当是“同步中”。
    final gate = Completer<void>();
    server.onPull = () => gate.future;
    late Future<SyncResult> running;
    await tester.runAsync(() async {
      running = scope!.accountServices.sync.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await openAccountPage(tester);
    await waitFor(tester, find.text('同步中'));
    expect(find.text('待修复'), findsNothing);
    expect(cloudRepairButton(), findsOneWidget);
    expect(localRepairButton(), findsOneWidget);
    expect(tester.widget<forui.FButton>(cloudRepairButton()).onPress, isNull);
    expect(tester.widget<forui.FButton>(localRepairButton()).onPress, isNull);
    expect(tester.takeException(), isNull);

    server.onPull = null;
    await tester.runAsync(() async {
      gate.complete();
      await running;
    });
  });

  testWidgets('摘要一致时账号页不显示不一致说明与两个修复入口', (tester) async {
    await pumpApp(tester);
    await seedMatched(tester);

    await openAccountPage(tester);
    await waitFor(tester, find.text('空闲'));

    expect(find.text('待修复'), findsNothing);
    expect(find.text('本机与云端不一致'), findsNothing);
    expect(find.textContaining('上次同步比较整库摘要时发现两边内容不同'), findsNothing);
    expect(cloudRepairButton(), findsNothing);
    expect(localRepairButton(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的页在摘要不一致时只标待修复，不放修复按钮', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);

    await openMinePage(tester);
    await waitFor(tester, find.text('待修复'));

    expect(find.text('待修复'), findsOneWidget);
    // 修复入口只在账号页：账号卡上不再放两个按钮，也不复制那段说明。
    expect(find.text('以云端为准修复'), findsNothing);
    expect(find.text('以本机为准修复'), findsNothing);
    expect(find.text('本机与云端不一致'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('摘要不一致且上次同步失败时，我的页按现有优先级显示同步失败', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);

    await openMinePage(tester);
    await waitFor(tester, find.text('待修复'));

    // 让这一轮同步在拉取时失败：同步服务记下上次错误，摘要不一致的标记仍留着。
    server.onPull = () => Future<void>.error(Exception('网络中断'));
    await tester.tap(find.widgetWithText(forui.FButton, '立即同步'));
    await waitFor(tester, find.text('同步失败'));
    server.onPull = null;

    final status = await tester.runAsync(
      () => scope!.accountServices.sync.status(),
    );
    expect(status!.digestMismatch, isTrue, reason: '前置状态：不一致标记仍在');
    expect(status.lastError, isNotNull, reason: '前置状态：上一轮同步失败');

    // 现状：先看上次错误，再看摘要不一致（mine_page.dart 的 _syncTag）。
    expect(find.text('同步失败'), findsOneWidget);
    expect(find.text('待修复'), findsNothing);
    expect(find.text('以云端为准修复'), findsNothing);
    expect(find.text('以本机为准修复'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('摘要修复之后我的页回到已同步', (tester) async {
    await pumpApp(tester);
    await seedCloudAheadMismatch(tester);

    // 在账号页按云端修复，两边重新一致；再到“我的”看账号卡的状态标。
    await openAccountPage(tester);
    await waitFor(tester, find.text('待修复'));
    await tester.tap(cloudRepairButton());
    await waitFor(tester, find.text('以云端为准修复会重做这台设备的同步'));
    await tester.tap(dialogAction('以云端为准修复'));
    await waitFor(tester, find.text('空闲'));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    await openMinePage(tester);
    await waitFor(tester, find.text('已同步'));

    expect(find.text('已同步'), findsOneWidget);
    expect(find.text('待修复'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
