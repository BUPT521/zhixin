// 账号页发送验证码之后的冷却说明：服务端对同一条登录方式一分钟内只发一封，
// 界面按同一个间隔禁用按钮并写出还要等多久，用户不必先点一次拿到 429 才知道。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/ui/account_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const email = 'resend-ui@example.com';

  late Directory directory;
  late FakeServer server;
  late Map<String, String> secrets;
  late GlobalKey<NavigatorState> navigator;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-verify-ui-');
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

  testWidgets('发送验证码之后按钮进入一分钟倒计时，冷却期间不能再点', (tester) async {
    await pumpApp(tester);
    await tester.runAsync(() async {
      await scope!.accountServices.account.register(
        identifier: email,
        password: 'password123',
      );
    });
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const AccountPage()),
    );
    await waitFor(tester, find.text('确认登录方式'));

    final send = find.widgetWithText(forui.FButton, '发送验证码');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await waitFor(tester, find.text('60 秒后可重发'));

    final cooling = tester.widget<forui.FButton>(
      find.widgetWithText(forui.FButton, '60 秒后可重发'),
    );
    expect(cooling.onPress, isNull, reason: '冷却期间不能重复发送');
    expect(
      find.textContaining('没收到先看垃圾邮件'),
      findsOneWidget,
      reason: '说明重发间隔与每日上限，避免用户反复点',
    );

    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(find.widgetWithText(forui.FButton, '重新发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
