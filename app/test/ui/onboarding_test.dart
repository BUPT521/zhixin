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

/// 首次启动引导的两步流程：登录页作首屏、同意对话框、本机模式、外观、
/// 老用户与版本升级。
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

  /// 填好登录表单；同意对话框在点登录之后才出现。
  Future<void> enterCredentials(
    WidgetTester tester, {
    required String email,
    String password = syncTestPassword,
  }) async {
    final fields = find.byType(EditableText);
    await tester.enterText(fields.at(0), email);
    await tester.enterText(fields.at(1), password);
    await tester.pump();
  }

  /// 等同意对话框出现，勾选之后点“同意并继续”。
  Future<void> agreeInDialog(WidgetTester tester) async {
    await pumpUntil(tester, find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await settle(tester);
  }

  /// 在假服务端先建好一个账号，用例用“登录”而不是“注册”走登录页。
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

  testWidgets('登录页是首屏，未同意时点登录先弹同意对话框', (tester) async {
    await openApp(tester);
    expect(find.text('登录或注册'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-step-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding-step-1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('onboarding-step-2')),
      findsNothing,
      reason: '同意不占一步，进度点只有两段',
    );
    expect(find.text('先在本机用'), findsOneWidget);
    expect(
      find.widgetWithText(forui.FButton, '上一步'),
      findsNothing,
      reason: '登录页是第一步，没有上一步',
    );

    await enterCredentials(tester, email: 'first@example.com');
    await tester.tap(find.widgetWithText(forui.FButton, '登录'));
    await pumpUntil(tester, find.text('开始使用前，先看这两份说明'));
    expect(server.loginRequests, 0, reason: '同意之前不发登录请求');
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

  testWidgets('先在本机用直接到外观，返回回到登录页', (tester) async {
    await openApp(tester);
    expect(find.text('登录或注册'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));
    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.stage, OnboardingStage.appearance);
      expect(record.agreed, isFalse, reason: '先在本机用记的是回答过，不是同意');
      expect(record.termsVersion, kTermsVersion);
      final telemetry = TelemetryStore(filesDir: directory.path);
      expect(await telemetry.noticeSeen(), isTrue);
      expect(await telemetry.enabled(), isFalse);
    });

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget);
  });

  testWidgets('底部上一步回到登录页，主操作仍然一步一页', (tester) async {
    await openApp(tester);
    expect(find.text('登录或注册'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));
    expect(find.widgetWithText(forui.FButton, '上一步'), findsOneWidget);

    await tester.tap(find.widgetWithText(forui.FButton, '上一步'));
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget, reason: '上一步回到登录页');

    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));
    expect(find.text('选择外观'), findsOneWidget);
  });

  testWidgets('左右划动与底栏同一套整页滑动', (tester) async {
    await openApp(tester);

    /// 在步骤内容的上缘开始一次横拖：那里只有标题或标记，不和表单抢手势。
    Future<TestGesture> startSwipe({double x = 60}) async {
      final topLeft = tester.getTopLeft(find.byType(TabSlideStack));
      return tester.startGesture(topLeft + Offset(x, 60));
    }

    // 登录页往前划与“先在本机用”相同：松手翻到外观。
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
    expect(find.text('选择外观'), findsOneWidget, reason: '左划进入外观');

    // 右划回到登录页；上一趟切换播完之前不接新的横拖。
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
    expect(find.text('登录或注册'), findsOneWidget, reason: '右划回到登录页');
  });

  testWidgets('点步骤点可以直接到外观，也可以点回来', (tester) async {
    await openApp(tester);

    await tester.tap(find.byKey(const ValueKey('onboarding-step-1')));
    await pumpUntil(tester, find.text('选择外观'));
    await tester.runAsync(() async {
      expect(
        (await OnboardingStore(directory.path).read()).stage,
        OnboardingStage.appearance,
        reason: '点进度点往前跳也先写盘',
      );
    });

    await tester.tap(find.byKey(const ValueKey('onboarding-step-0')));
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget, reason: '点回来');
  });

  testWidgets('先在本机用进入本机模式，不调用上报与更新检查', (tester) async {
    await openApp(tester);
    await tester.tap(find.widgetWithText(forui.FButton, '先在本机用'));
    await pumpUntil(tester, find.text('选择外观'));

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

  testWidgets('同意对话框里关掉匿名统计，同意的值写进首次说明状态', (tester) async {
    await openApp(tester);
    await enterCredentials(tester, email: 'forgot@example.com');
    // 找回密码同样要先同意，用它可以打开对话框而不提交登录。
    await tester.tap(find.widgetWithText(forui.FButton, '忘记密码'));
    await pumpUntil(tester, find.text('我已阅读并同意《用户须知》与《隐私政策》'));

    // 关掉匿名使用统计，再看这个值有没有随同意一起写下去。
    await tester.tap(find.text('匿名使用统计'));
    await tester.pump();
    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    expect(
      tester
          .widget<forui.FButton>(find.widgetWithText(forui.FButton, '同意并继续'))
          .onPress,
      isNotNull,
      reason: '勾选之后才能同意',
    );
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    // 同意之后接着打开找回密码；这一页出现时同意与说明状态都已经写完。
    await pumpUntil(tester, find.text('发送验证码'));
    expect(
      find.text('我已阅读并同意《用户须知》与《隐私政策》'),
      findsNothing,
      reason: '同意之后对话框关闭',
    );

    await tester.runAsync(() async {
      final telemetry = TelemetryStore(filesDir: directory.path);
      expect(await telemetry.noticeSeen(), isTrue);
      expect(await telemetry.enabled(), isFalse);
    });
    expect(server.actives, isEmpty, reason: '引导里同意时不发这次上报');
    expect(server.loginRequests, 0, reason: '取消的登录没有提交');
  });

  testWidgets('老用户在首页补同意，同意之后恢复联网', (tester) async {
    await openApp(tester, existingUser: true);
    await pumpUntil(tester, find.byType(HomeShell));
    expect(find.byType(OnboardingPage), findsNothing, reason: '老用户不走登录与外观');
    await pumpUntil(tester, find.text('开始使用前，先看这两份说明'));

    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await settle(tester);
    await pumpUntilCondition(
      tester,
      () => updateChecks > 0,
      reason: '同意之后首页补做更新检查',
    );

    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.completed, isTrue);
      expect(record.termsVersion, kTermsVersion);
      expect(record.agreed, isTrue);
    });
  });

  testWidgets('须知版本升级时在首页补同意', (tester) async {
    await openApp(
      tester,
      record: OnboardingRecord(
        completed: true,
        termsVersion: kTermsVersion - 1,
        agreed: true,
      ),
    );
    await pumpUntil(tester, find.byType(HomeShell));
    await pumpUntil(tester, find.text('用户须知有更新'));
    expect(find.byType(OnboardingPage), findsNothing);

    await tester.tap(find.text('我已阅读并同意《用户须知》与《隐私政策》'));
    await tester.pump();
    await tester.tap(find.widgetWithText(forui.FButton, '同意并继续'));
    await settle(tester);
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

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('登录或注册'), findsOneWidget);

    await enterCredentials(tester, email: 'onboarding@example.com');
    // 先在本机用之后没有同意，登录时补一次对话框。
    await tester.tap(find.widgetWithText(forui.FButton, '注册'));
    await agreeInDialog(tester);
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
    await tester.runAsync(() async {
      expect(
        (await OnboardingStore(directory.path).read()).stage,
        OnboardingStage.appearance,
      );
    });
  });

  testWidgets('登录成功之后按重建后的登录态到外观，只登录一次', (tester) async {
    final spaces = AppSpaces(
      AppPaths(directory.path, cacheDir: directory.path),
    );
    const email = 'login-onboarding@example.com';
    await tester.runAsync(() => seedAccountOnServer(email));
    await openApp(tester, spaces: spaces);

    await enterCredentials(tester, email: email);
    await tester.tap(find.widgetWithText(forui.FButton, '登录'));
    await agreeInDialog(tester);
    await pumpUntil(tester, find.text('选择外观'));

    // 换空间之后的新应用根还在开库，收尾前等它就绪，tearDown 才能关干净。
    scope = tester.state<AppScopeState>(find.byType(AppScope));
    await waitReady(tester, scope!);
    await settle(tester);

    expect(find.text('登录或注册'), findsNothing, reason: '重建之后不再退回登录页');
    expect(
      find.widgetWithText(forui.FButton, '登录'),
      findsNothing,
      reason: '外观页没有登录表单',
    );
    expect(server.loginRequests, 1, reason: '登录成功之后没有再次登录');
    await tester.runAsync(() async {
      final record = await OnboardingStore(directory.path).read();
      expect(record.stage, OnboardingStage.appearance);
      expect(record.completed, isFalse, reason: '还要走完外观这一步');
    });
  });

  testWidgets('忘记密码先取得同意，再直接打开重设表单', (tester) async {
    await openApp(tester);

    await enterCredentials(tester, email: 'forgot@example.com');
    await tester.tap(find.widgetWithText(forui.FButton, '忘记密码'));
    await agreeInDialog(tester);
    await pumpUntil(tester, find.text('发送验证码'));
    // 页面过渡走完，下面那一层（引导登录页）才从界面上退下去。
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
      reason: '登录页填过的邮箱带过去',
    );

    await tester.binding.handlePopRoute();
    await settle(tester, rounds: 60);
    expect(find.text('登录或注册'), findsOneWidget);
    expect(find.text('找回密码'), findsNothing);
    expect(server.loginRequests, 0);
  });
}
