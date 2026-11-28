import 'dart:convert';
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
    // 第二步从右边滑进来，等它落定再让用例点第二步里的东西。
    await settle(tester);
  }

  /// 在假服务端先建好一个账号，用例用“登录”而不是“注册”走第二步。
  Future<void> seedAccountOnServer(String email) async {
    await server.client.post(
      Uri.parse('$syncTestServerUrl/v1/auth/register'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'identifier': email,
        'password': syncTestPassword,
        'device_name': 'seed',
      }),
    );
  }

  testWidgets('未勾选同意时按钮不可点，勾选之后可以继续', (tester) async {
    await openApp(tester);
    expect(find.text('同意并继续'), findsOneWidget);
    expect(
      tester
          .widget<forui.FButton>(find.widgetWithText(forui.FButton, '同意并继续'))
          .onPress,
      isNull,
      reason: '没有勾选就不同意',
    );

    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    expect(
      tester
          .widget<forui.FButton>(find.widgetWithText(forui.FButton, '同意并继续'))
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
      expect(
        (await OnboardingStore(directory.path).read()).stage,
        OnboardingStage.login,
        reason: '进入第二步之前先写盘，登录换空间之后才知道该停在哪一步',
      );
    });

    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));
    await tester.runAsync(() async {
      expect(
        (await OnboardingStore(directory.path).read()).stage,
        OnboardingStage.appearance,
      );
    });

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget);
  });

  testWidgets('底部上一步回到须知，主操作仍然一步一页', (tester) async {
    await openApp(tester);
    const termsTitle = '开始使用前，先看这两份说明';
    expect(find.text(termsTitle), findsOneWidget);
    expect(
      find.widgetWithText(forui.FButton, '上一步'),
      findsNothing,
      reason: '第一步没有上一步',
    );

    await agreeTerms(tester);
    expect(find.widgetWithText(forui.FButton, '上一步'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '上一步'));
    await settle(tester);
    expect(find.text(termsTitle), findsOneWidget, reason: '上一步回到须知');
    // 回来时保留勾选，可以直接再往后走。
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await pumpUntil(tester, find.text('登录或注册'));
    expect(find.text('登录或注册'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));
    expect(find.text('选择外观'), findsOneWidget);
  });

  testWidgets('左右划动与底栏同一套整页滑动，没勾选同意时往前划不动', (tester) async {
    await openApp(tester);
    const termsTitle = '开始使用前，先看这两份说明';

    /// 在步骤内容的上缘开始一次横拖：那里只有标题，不和表单抢手势。
    Future<TestGesture> startSwipe({double x = 60}) async {
      final topLeft = tester.getTopLeft(find.byType(TabSlideStack));
      return tester.startGesture(topLeft + Offset(x, 60));
    }

    // 没勾选时左划不跟手，松手也不切到下一步。
    final resting = tester.getTopLeft(find.text(termsTitle)).dx;
    final blocked = await startSwipe(x: 320);
    await blocked.moveBy(const Offset(-60, 0));
    await blocked.moveBy(const Offset(-120, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text(termsTitle)).dx,
      resting,
      reason: '没勾选同意时左划不跟手',
    );
    await blocked.up();
    await tester.pumpAndSettle();
    expect(find.text(termsTitle), findsOneWidget);

    await agreeTerms(tester);

    // 勾选之后左划：登录这一步跟着手指往左走，松手翻到外观。
    final loginDx = tester.getTopLeft(find.text('登录或注册')).dx;
    final forward = await startSwipe(x: 320);
    await forward.moveBy(const Offset(-60, 0));
    await forward.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('登录或注册')).dx,
      lessThan(loginDx - 30),
      reason: '拖动途中当前这一步跟着手指走',
    );
    await forward.moveBy(const Offset(-150, 0));
    await forward.up();
    await pumpUntil(tester, find.text('选择外观'));
    await settle(tester);
    expect(find.text('选择外观'), findsOneWidget, reason: '左划进入下一步');

    // 右划回到上一步；上一趟切换播完之前不接新的横拖。
    final appearanceDx = tester.getTopLeft(find.text('选择外观')).dx;
    final back = await startSwipe();
    await back.moveBy(const Offset(60, 0));
    await back.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('选择外观')).dx,
      greaterThan(appearanceDx + 30),
      reason: '右划时外观这一步跟着手指往右走',
    );
    await back.moveBy(const Offset(120, 0));
    await back.up();
    await pumpUntil(tester, find.text('登录或注册'));
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget, reason: '右划回到上一步');
  });

  testWidgets('不同意之后外观页向右划不翻页，回第一步仍用上一步', (tester) async {
    await openApp(tester);
    await tester.tap(find.text('不同意，仅在本机使用'));
    await pumpUntil(tester, find.text('选择外观'));
    await settle(tester);

    // 没有登录这一步，右划要回的那一步不挨着外观页，因此不跟手。
    final dx = tester.getTopLeft(find.text('选择外观')).dx;
    final gesture = await tester.startGesture(
      tester.getTopLeft(find.byType(TabSlideStack)) + const Offset(60, 60),
    );
    await gesture.moveBy(const Offset(60, 0));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('选择外观')).dx,
      dx,
      reason: '不同意之后没有登录这一步，右划不跟手',
    );
    await gesture.up();
    await settle(tester);
    expect(find.text('选择外观'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '上一步'));
    await pumpUntil(tester, find.text('开始使用前，先看这两份说明'));
    await settle(tester);
    expect(find.text('开始使用前，先看这两份说明'), findsOneWidget);
  });

  testWidgets('点步骤点可以回看，也可以跳过登录直接到外观', (tester) async {
    await openApp(tester);
    const termsTitle = '开始使用前，先看这两份说明';

    // 还没处理须知时点第三步不动。
    await tester.tap(find.byKey(const ValueKey('onboarding-step-2')));
    await settle(tester);
    expect(find.text(termsTitle), findsOneWidget);

    await agreeTerms(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding-step-2')));
    await pumpUntil(tester, find.text('选择外观'));
    await tester.runAsync(() async {
      expect(
        (await OnboardingStore(directory.path).read()).stage,
        OnboardingStage.appearance,
        reason: '点步骤点往前跳也先写盘',
      );
    });

    await tester.tap(find.byKey(const ValueKey('onboarding-step-1')));
    await pumpUntil(tester, find.text('登录或注册'));
    await tester.tap(find.byKey(const ValueKey('onboarding-step-0')));
    await settle(tester);
    expect(find.text(termsTitle), findsOneWidget, reason: '回看第一步');
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
    final spaces = AppSpaces(
      AppPaths(directory.path, cacheDir: directory.path),
    );
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
    // 新页是淡入的，语义树等动画走完才完整；按读屏名称点色块前先等一帧。
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('苔绿主题色'));
    await settle(tester);
    // 换主题色要先写完文件再改值，负载高时一次 settle 可能还没走到重建。
    await pumpUntilCondition(
      tester,
      () =>
          Theme.of(tester.element(find.byType(OnboardingPage)))
              .colorScheme
              .primary ==
          ZhixinAccent.moss.light,
      reason: '点选的苔绿主题色没有生效',
    );
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
    // 新应用根装的控制器从换过来的目录里读外观，文件读完才换值；等到颜色
    // 真正生效再断言，避免负载高时在读完文件之前下结论。
    await pumpUntilCondition(
      tester,
      () =>
          Theme.of(tester.element(find.byType(OnboardingPage)))
              .colorScheme
              .primary ==
          ZhixinAccent.moss.light,
      reason: '换空间之后此前选的外观没有生效',
    );
    expect(
      Theme.of(tester.element(find.byType(OnboardingPage))).colorScheme.primary,
      ZhixinAccent.moss.light,
      reason: '换空间时未登录目录整体改名，之前选的外观跟着保留',
    );
    await tester.runAsync(() async {
      expect(
        (await OnboardingStore(directory.path).read()).stage,
        OnboardingStage.appearance,
      );
    });
  });

  testWidgets('登录成功之后按重建后的登录态到第三步，只登录一次', (tester) async {
    final spaces = AppSpaces(
      AppPaths(directory.path, cacheDir: directory.path),
    );
    const email = 'login-onboarding@example.com';
    await tester.runAsync(() => seedAccountOnServer(email));
    await openApp(tester, spaces: spaces);
    await agreeTerms(tester);

    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), email);
    await tester.enterText(fields.at(1), syncTestPassword);
    await tester.tap(find.widgetWithText(forui.FButton, '登录'));
    await pumpUntil(tester, find.text('选择外观'));

    // 换空间之后的新应用根还在开库，收尾前等它就绪，tearDown 才能关干净。
    scope = tester.state<AppScopeState>(find.byType(AppScope));
    await waitReady(tester, scope!);
    await settle(tester);

    expect(find.text('登录或注册'), findsNothing, reason: '重建之后不再退回第二步');
    expect(
      find.widgetWithText(forui.FButton, '登录'),
      findsNothing,
      reason: '第三步没有登录表单',
    );
    expect(server.loginRequests, 1, reason: '登录成功之后没有再次登录');
    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.stage, OnboardingStage.appearance);
      expect(record.completed, isFalse, reason: '还要走完外观这一步');
    });
  });

  testWidgets('忘记密码直接打开重设表单，返回后仍停在第二步', (tester) async {
    await openApp(tester);
    await agreeTerms(tester);

    await tester.enterText(
      find.byType(EditableText).at(0),
      'forgot@example.com',
    );
    await tester.tap(find.widgetWithText(forui.FButton, '忘记密码'));
    await pumpUntil(tester, find.text('发送验证码'));
    // 页面过渡走完，下面那一层（引导第二步）才从界面上退下去。
    await settle(tester);

    expect(find.text('找回密码'), findsWidgets, reason: '直接落在找回密码形态，不用进去再点一次');
    expect(
      find.widgetWithText(forui.FButton, '登录'),
      findsNothing,
      reason: '重设表单里没有登录按钮',
    );
    expect(find.text('账号与云同步'), findsNothing, reason: '不显示账号页的其他区块');
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText).at(0))
          .controller
          .text,
      'forgot@example.com',
      reason: '第二步填过的邮箱带过去',
    );

    await tester.binding.handlePopRoute();
    await settle(tester, rounds: 60);
    expect(find.text('登录或注册'), findsOneWidget);
    expect(find.text('找回密码'), findsNothing);
    expect(server.loginRequests, 0);
  });
}
