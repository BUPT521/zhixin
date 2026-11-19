import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/vector/embedding_config_store.dart';
import 'package:zhixin/ui/embedding_settings_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/telemetry.dart';

/// 语义索引页选择知新服务：未登录时说明要先登录，登录之后从服务端的嵌入模型
/// 里选，维度由服务端给出，保存的配置不带地址与令牌。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Map<String, String> secrets;
  late FakeServer server;
  AppScopeState? scope;
  final previewKey = GlobalKey();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-embed-server-');
    await disableTelemetryForTests(directory.path);
    secrets = {};
    server = FakeServer();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    // 安全存储按键保存：登录会话与嵌入配置都要在页面之间读得回来。
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

  Future<void> preview(WidgetTester tester, String name) async {
    final target = Platform.environment['ZHIXIN_UI_PREVIEW_DIR'];
    if (target == null) return;
    final boundary =
        previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(target).create(recursive: true);
      await File('$target/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// 先装应用根，登录（可选）之后再推入语义索引页，让页面首读拿到登录状态。
  Future<void> openPage(WidgetTester tester, {required bool signIn}) async {
    tester.view.physicalSize = const Size(390, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final navigator = GlobalKey<NavigatorState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: previewKey,
          child: MaterialApp(
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
                  themeMode: ThemeModeController(),
                  serverClientFactory: (baseUrl) =>
                      ServerClient(baseUrl: baseUrl, httpClient: server.client),
                  child: child!,
                ),
              ),
            ),
            home: const SizedBox.shrink(),
          ),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
      if (signIn) {
        await scope!.accountServices.account.register(
          email: 'embed@example.com',
          password: 'password123',
        );
      }
    });
    await tester.pump();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const EmbeddingSettingsPage()),
    );
    await waitFor(tester, find.text('索引状态'));
  }

  /// 预先存一份选了知新服务的配置，页面打开时就停在这一来源上。
  void storeServerConfig({String model = ''}) {
    secrets[EmbeddingConfigStore.storageKey] = jsonEncode(
      EmbeddingConfig(
        enabled: false,
        provider: 'server',
        model: model,
        dim: 1024,
      ).toJson(),
    );
  }

  testWidgets('未登录时选择知新服务，说明要先登录，保存被拦下', (tester) async {
    storeServerConfig();
    await openPage(tester, signIn: false);

    await waitFor(tester, find.textContaining('还没有登录。知新服务用登录账号'));
    expect(find.text('知新服务（登录账号）'), findsOneWidget);
    expect(find.text('接口地址'), findsNothing, reason: '知新服务不需要填地址');
    await preview(tester, 'embedding-server-signed-out');

    await tester.tap(
      find.descendant(
        of: find.byType(forui.FSwitch),
        matching: find.text('启用语义索引'),
      ),
    );
    await tester.pump();
    final save = find.text('保存并更新索引');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await waitFor(tester, find.textContaining('知新服务要先登录'));
  });

  testWidgets('登录之后从服务端的嵌入模型里选，维度由服务端给出', (tester) async {
    storeServerConfig(model: 'bge-m3');
    await openPage(tester, signIn: true);

    await waitFor(tester, find.text('bge-m3（4 维）'));
    expect(find.text('deepseek-flash'), findsNothing, reason: '聊天模型不进嵌入选项');
    expect(find.text('向量维度 4，由服务端给出。'), findsOneWidget);
    await preview(tester, 'embedding-server-signed-in');

    await tester.tap(
      find.descendant(
        of: find.byType(forui.FSwitch),
        matching: find.text('启用语义索引'),
      ),
    );
    await tester.pump();
    final all = find.text('本机全部记录');
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pump();
    final save = find.text('保存并更新索引');
    await tester.ensureVisible(save);
    await tester.tap(save);
    // 保存之后接着更新索引；测试环境里向量库是否打得开与这里无关，只核对
    // 写进安全存储的配置。
    await waitFor(tester, find.textContaining('设置已经保存'));

    final stored = jsonDecode(
      secrets[EmbeddingConfigStore.storageKey]!,
    ) as Map<String, Object?>;
    expect(stored['provider'], 'server');
    expect(stored['model'], 'bge-m3');
    expect(stored['dim'], 4);
    expect(stored['base_url'], '');
    expect(stored['api_key'], '', reason: '访问令牌不写进配置');
    await preview(tester, 'embedding-server-saved');
  });
}
