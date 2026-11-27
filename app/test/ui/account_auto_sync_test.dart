// 账号页保存自动同步开关之后，账号快照要由服务返回，登录方式与额度入口不能丢（A1）。
//
// 现状：页面自己拼一份只有服务地址、会话、开关与默认地址四项的快照，资料与登录
// 方式变成空值，页面当场回到“登录方式暂时无法读取”“还没有确认任何登录方式”，
// 额度购买面板随之消失，直到重新进入页面。用例按这条路径核对。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/ui/account_page.dart';
import 'package:zhixin/ui/quota_purchase_panel.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const email = 'autosync-ui@example.com';

  late Directory directory;
  late FakeServer server;
  late Map<String, String> secrets;
  late GlobalKey<NavigatorState> navigator;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-autosync-ui-');
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
      await tester.runAsync(() async {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 登录并确认唯一的登录方式：额度购买入口只在确认之后出现，开关前后的两份
  /// 快照都要能看到它才有对照意义。
  Future<void> signInVerified(WidgetTester tester) async {
    await tester.runAsync(() async {
      final account = scope!.accountServices.account;
      await account.register(identifier: email, password: 'password123');
      final profile = (await account.refreshAccount()).profile!;
      final identity = profile.identities.single;
      await account.requestIdentityVerification(identity.id);
      await account.confirmIdentityVerification(
        identity.id,
        server.codeFor(email, 'verify_contact')!,
      );
    });
  }

  /// 开关切到 [value] 之后等界面跟着变。
  Future<void> waitForAutoSync(
    WidgetTester tester, {
    required bool value,
  }) async {
    for (var round = 0; round < 150; round++) {
      await tester.runAsync(() async {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      final switches = find.byType(forui.FSwitch);
      if (switches.evaluate().isEmpty) continue;
      if (tester.widget<forui.FSwitch>(switches).value == value) return;
    }
    fail('等待自动同步开关变成 $value 超时');
  }

  testWidgets('保存自动同步开关之后登录方式与额度入口仍在', (tester) async {
    await pumpApp(tester);
    await signInVerified(tester);
    // 先开着自动同步：关掉时不弹确认框，用例只核对保存之后的快照。
    await tester.runAsync(
      () => scope!.accountServices.account.setAutoSync(true),
    );

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const AccountPage()),
    );
    await waitFor(tester, find.text('自动同步'));
    // 前置状态：登录方式已经读到、额度购买入口在页面上。
    expect(find.text('登录方式暂时无法读取'), findsNothing);
    expect(find.textContaining(email), findsOneWidget);
    expect(find.byType(QuotaPurchasePanel), findsOneWidget);
    expect(
      tester.widget<forui.FSwitch>(find.byType(forui.FSwitch)).value,
      isTrue,
    );

    // 关掉自动同步：页面只接收服务保存之后的快照。
    await tester.ensureVisible(find.text('自动同步'));
    await tester.tap(find.text('自动同步'));
    await waitForAutoSync(tester, value: false);

    expect(find.text('登录方式暂时无法读取'), findsNothing, reason: '登录方式列表不能丢');
    expect(
      find.text('还没有确认任何登录方式；先确认一种，忘记密码时才能收到重设验证码。'),
      findsNothing,
      reason: '已确认的登录方式不能因为保存开关退回未确认',
    );
    expect(find.textContaining(email), findsOneWidget);
    expect(find.byType(QuotaPurchasePanel), findsOneWidget, reason: '额度入口仍在');
    expect(tester.takeException(), isNull);
  });
}
