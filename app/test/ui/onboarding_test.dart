import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/application/update_check_service.dart';
import 'package:zhixin/data/cloud/server_client.dart';
import 'package:zhixin/data/cloud/telemetry_store.dart';
import 'package:zhixin/platform/app_paths.dart';
import 'package:zhixin/platform/onboarding_store.dart';
import 'package:zhixin/ui/home_shell.dart';
import 'package:zhixin/ui/onboarding_page.dart';
import 'package:zhixin/ui/theme.dart';
import 'package:zhixin/ui/theme_accent_controller.dart';
import 'package:zhixin/ui/theme_mode_controller.dart';
import 'package:zhixin/platform/theme_accent_store.dart';
import 'package:zhixin/platform/theme_mode_store.dart';

import '../support/app_scope_teardown.dart';
import '../support/fake_server.dart';
import '../support/sync_rig.dart';
import '../support/telemetry.dart';

/// 首次启动引导的三步流程：同意、本机模式、登录、外观、老用户与版本升级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late FakeServer server;
  late Map<String, String> secrets;
  late int updateChecks;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-onboarding-ui-');
    server = FakeServer();
    secrets = {};
    updateChecks = 0;
    FlutterSecureStorage.setMockInitialValues({});
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

  UpdateCheckService countingUpdates() => UpdateCheckService(
    serverBaseUrl: () async => syncTestServerUrl,
    appVersion: '0.3.0+4',
    publicKeyPem: '内置公钥',
    fetchReleases: (_) async {
      updateChecks++;
      return const [];
    },
    verifySignature: ({
      required publicKeyPem,
      required sha256Hex,
      required signatureBase64,
    }) async => true,
  );

  /// 等界面出现某个东西：真实等待让文件与网络完成，假时间让界面重建。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 400,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  Future<void> pumpUntilCondition(
    WidgetTester tester,
    bool Function() condition, {
    int rounds = 400,
    required String reason,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (condition()) return;
    }
    fail('等待条件超时：$reason');
  }

  Future<void> settle(WidgetTester tester, {int rounds = 20}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 等换空间之后新建的应用根打开数据库。
  ///
  /// 这个应用根是在测试的假异步区里建起来的，直接从 `runAsync` 里等它的 `ready`
  /// 会跨区等待而卡住；这里按帧推进，让它自己的异步继续走完。
  Future<void> waitReady(WidgetTester tester, AppScopeState state) async {
    var done = false;
    Object? failure;
    state.ready.then(
      (_) => done = true,
      onError: (Object error, StackTrace _) {
        failure = error;
        done = true;
      },
    );
    for (var round = 0; round < 600 && !done; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(failure, isNull);
    expect(done, isTrue, reason: '换空间之后的应用根没有在时限内打开');
  }

  Future<void> openApp(
    WidgetTester tester, {
    OnboardingRecord record = const OnboardingRecord(),
    bool existingUser = false,
    bool signedIn = false,
    AppSpaces? spaces,
    String spaceId = AppSpaces.local,
    ThemeAccentController? themeAccent,
    ThemeModeController? themeMode,
  }) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ZhixinApp(
          onboardingStore: OnboardingStore(directory.path),
          onboardingRecord: record,
          existingUser: existingUser,
          signedIn: signedIn,
          spaces: spaces,
          spaceId: spaceId,
          themeAccent: themeAccent,
          themeMode: themeMode,
          updates: countingUpdates(),
          serverClientFactory: (base) =>
              ServerClient(baseUrl: base, httpClient: server.client),
        ),
      );
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await pumpUntil(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is OnboardingPage || widget is HomeShell,
      ),
    );
  }

  Future<void> agreeTerms(WidgetTester tester) async {
    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await pumpUntil(tester, find.text('登录或注册'));
  }

  testWidgets('未勾选同意时按钮不可点，勾选之后可以继续', (tester) async {
    await openApp(tester);
    expect(find.text('同意并继续'), findsOneWidget);
    expect(
      tester
          .widget<forui.FButton>(
            find.widgetWithText(forui.FButton, '同意并继续'),
          )
          .onPress,
      isNull,
      reason: '没有勾选就不同意',
    );

    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    expect(
      tester
          .widget<forui.FButton>(
            find.widgetWithText(forui.FButton, '同意并继续'),
          )
          .onPress,
      isNotNull,
    );
    // 按下的反馈与选中动画要走完，别把计时器留给用例收尾检查。
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('同意之后进入登录这一步，跳过登录可以到外观并返回', (tester) async {
    await openApp(tester);
    await agreeTerms(tester);

    await tester.runAsync(() async {
      final telemetry = TelemetryStore(filesDir: directory.path);
      expect(await telemetry.noticeSeen(), isTrue);
      expect(await telemetry.enabled(), isTrue);
    });

    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget);
  });

  testWidgets('不同意进入本机模式，不调用上报与更新检查', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('不同意，仅在本机使用'));
    await pumpUntil(tester, find.text('选择外观'));
    expect(find.text('登录或注册'), findsNothing);

    await tester.tap(find.widgetWithText(forui.FButton, '完成'));
    await pumpUntil(tester, find.byType(HomeShell));
    await settle(tester);

    expect(server.actives, isEmpty, reason: '不同意时不上报匿名活跃');
    expect(updateChecks, 0, reason: '不同意时不检查更新');
    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.completed, isTrue);
      expect(record.agreed, isFalse);
      final telemetry = TelemetryStore(filesDir: directory.path);
      expect(await telemetry.noticeSeen(), isTrue);
      expect(await telemetry.enabled(), isFalse);
    });
  });

  testWidgets('同意时把匿名统计开关的值写进首次说明状态', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    // 关掉匿名使用统计，再看这个值有没有随同意一起写下去。
    await tester.tap(find.text('匿名使用统计'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await pumpUntil(tester, find.text('登录或注册'));

    await tester.runAsync(() async {
      final telemetry = TelemetryStore(filesDir: directory.path);
      expect(await telemetry.noticeSeen(), isTrue);
      expect(await telemetry.enabled(), isFalse);
    });
    expect(server.actives, isEmpty);
  });

  testWidgets('老用户只看到第一步，同意之后直接进入首页', (tester) async {
    await openApp(tester, existingUser: true);
    expect(find.text('用户须知有更新'), findsOneWidget);
    expect(find.text('登录或注册'), findsNothing);
    expect(find.text('选择外观'), findsNothing);

    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await pumpUntil(tester, find.byType(HomeShell));
    await pumpUntilCondition(
      tester,
      () => updateChecks > 0,
      reason: '同意之后首页补做更新检查',
    );
    expect(updateChecks, greaterThan(0));

    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.completed, isTrue);
      expect(record.termsVersion, kTermsVersion);
      expect(record.agreed, isTrue);
    });
  });

  testWidgets('须知版本升级时只重新显示第一步', (tester) async {
    await openApp(
      tester,
      record: OnboardingRecord(
        completed: true,
        termsVersion: kTermsVersion - 1,
        agreed: true,
      ),
    );
    expect(find.text('用户须知有更新'), findsOneWidget);
    expect(find.text('登录或注册'), findsNothing);
    expect(find.text('选择外观'), findsNothing);

    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await pumpUntil(tester, find.byType(HomeShell));

    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.termsVersion, kTermsVersion);
      expect(record.agreed, isTrue);
    });
  });

  testWidgets('完成之后再次启动直接进入首页', (tester) async {
    await tester.runAsync(() => disableTelemetryForTests(directory.path));
    await openApp(
      tester,
      record: const OnboardingRecord(
        completed: true,
        termsVersion: kTermsVersion,
        agreed: true,
      ),
    );
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(OnboardingPage), findsNothing);
  });

  testWidgets('登录成功之后子树重建仍停在外观，此前选的外观保留', (tester) async {
    final spaces = AppSpaces(AppPaths(directory.path, cacheDir: directory.path));
    final localDir = spaces.pathsFor(AppSpaces.local).filesDir;
    final themeAccent = ThemeAccentController(
      store: ThemeAccentStore(localDir),
    );
    final themeMode = ThemeModeController(store: ThemeModeStore(localDir));
    addTearDown(themeAccent.dispose);
    addTearDown(themeMode.dispose);
    await openApp(
      tester,
      spaces: spaces,
      themeAccent: themeAccent,
      themeMode: themeMode,
    );
    await agreeTerms(tester);

    // 先到外观选一个主题色，再返回登录，验证换空间之后这一步与外观都还在。
    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));
    await tester.tap(find.bySemanticsLabel('苔绿主题色'));
    await settle(tester);
    expect(
      Theme.of(tester.element(find.byType(OnboardingPage))).colorScheme.primary,
      ZhixinAccent.moss.light,
    );

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget);

    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), 'onboarding@example.com');
    await tester.enterText(fields.at(1), syncTestPassword);
    // 用一个还没注册过的邮箱走注册并登录，验证换空间之后引导仍停在外观这一页。
    await tester.tap(find.widgetWithText(forui.FButton, '注册'));
    await pumpUntil(tester, find.text('选择外观'));

    // 换空间之后的新应用根还在开库，收尾前等它就绪，tearDown 才能关干净。
    scope = tester.state<AppScopeState>(find.byType(AppScope));
    await waitReady(tester, scope!);

    expect(scope!.spaceId, isNot(AppSpaces.local), reason: '第一次登录换成账号空间');
    expect(find.byType(HomeShell), findsNothing, reason: '引导还没走完');
    expect(
      Theme.of(tester.element(find.byType(OnboardingPage))).colorScheme.primary,
      ZhixinAccent.moss.light,
      reason: '换空间时未登录目录整体改名，之前选的外观跟着保留',
    );
  });
}
