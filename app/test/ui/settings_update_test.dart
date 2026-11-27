import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/update_check_service.dart';
import 'package:zhixin/data/cloud/release_verification.dart';
import 'package:zhixin/domain/models/server_models.dart';
import 'package:zhixin/ui/settings_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';

import '../support/app_scope_teardown.dart';

/// 设置页的手动“检查更新”：已是最新、有更新与检查失败三种结果。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  final hash = releaseSha256Hex(utf8.encode('zhixin apk bytes'));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'zhixin-settings-update-',
    );
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

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 100,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  UpdateCheckService service({
    List<ServerRelease> releases = const [],
    bool failFetch = false,
    bool signatureValid = true,
  }) => UpdateCheckService(
    serverBaseUrl: () async => 'http://server.test',
    appVersion: '0.1.1-dev+2',
    publicKeyPem: '内置公钥',
    fetchReleases: (_) async {
      if (failFetch) throw const ServerProblem.offline('测试断网');
      return releases;
    },
    verifySignature: ({
      required publicKeyPem,
      required sha256Hex,
      required signatureBase64,
    }) async => signatureValid,
  );

  ServerRelease release({String minVersion = '0.1.0'}) => ServerRelease(
    platform: 'android',
    version: '0.2.0',
    build: 1,
    url: 'https://example.test/zhixin.apk',
    sha256: hash,
    signature: 'c2lnbmF0dXJl',
    minVersion: minVersion,
    notes: '登录、云端备份与同步',
  );

  Future<void> pumpSettings(
    WidgetTester tester,
    UpdateCheckService updates,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
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
                child: child!,
              ),
            ),
          ),
          home: SettingsPage(updates: updates),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    // 首读期间是骨架，等语义索引入口出现再操作。
    await waitFor(tester, find.text('语义索引'));
  }

  Future<void> tapCheckUpdates(WidgetTester tester) async {
    final tile = find.text('检查更新');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
  }

  testWidgets('没有更新时说明已经是最新版本', (tester) async {
    await pumpSettings(tester, service());
    await tapCheckUpdates(tester);
    await waitFor(tester, find.textContaining('已经是最新版本'));
    expect(find.textContaining('已经是最新版本'), findsOneWidget);
  });

  testWidgets('有更新时说明新版本并弹出提示', (tester) async {
    await pumpSettings(tester, service(releases: [release()]));
    await tapCheckUpdates(tester);
    await waitFor(tester, find.text('有新版本可用'));

    // 提示里给出当前版本、新版本与更新说明，并给打开下载地址的按钮。
    expect(find.text('有新版本可用'), findsOneWidget);
    expect(find.textContaining('新版本 0.2.0'), findsWidgets);
    expect(find.text('登录、云端备份与同步'), findsOneWidget);
    expect(find.widgetWithText(forui.FButton, '打开下载地址'), findsOneWidget);

    await tester.tap(find.text('以后再说'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('有新版本可用'), findsNothing);
    expect(find.textContaining('有新版本 0.2.0'), findsOneWidget);
  });

  testWidgets('低于最低版本时提示建议尽快更新，但不阻断使用', (tester) async {
    await pumpSettings(
      tester,
      service(releases: [release(minVersion: '0.2.0')]),
    );
    await tapCheckUpdates(tester);
    await waitFor(tester, find.text('建议尽快更新'));

    // 文案说明云端功能可能不可用，同时保留“以后再说”，本机功能继续可用。
    expect(find.textContaining('云端同步与在线模型可能不可用'), findsOneWidget);
    expect(find.textContaining('请更新之后继续使用'), findsNothing);
    expect(find.text('以后再说'), findsOneWidget);

    await tester.tap(find.text('以后再说'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('建议尽快更新'), findsNothing);
  });

  testWidgets('网络失败时说明检查失败，没有更新提示', (tester) async {
    await pumpSettings(tester, service(failFetch: true));
    await tapCheckUpdates(tester);
    await waitFor(tester, find.textContaining('检查更新失败'));
    expect(find.textContaining('无法连接服务端'), findsOneWidget);
    expect(find.text('有新版本可用'), findsNothing);
  });
}
