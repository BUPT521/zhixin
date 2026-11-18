import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/data/cloud/telemetry_store.dart';

import '../support/app_scope_teardown.dart';

/// 首次使用的匿名统计说明（ADR-0019）：启动之后只弹一次，说明采集内容与用途，
/// 并提供“关闭上报”。选择结果写进本机状态在服务层用例里覆盖，这里只核对说明
/// 在哪一次启动出现、看了之后不再出现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-notice-');
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

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const ZhixinApp());
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    for (var round = 0; round < 60; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (find.text('关于使用统计').evaluate().isNotEmpty) return;
    }
    fail('首次使用说明没有出现');
  }

  testWidgets('首次启动说明采集内容，可以关闭上报', (tester) async {
    await openApp(tester);
    expect(find.text('关于使用统计'), findsOneWidget);
    expect(find.textContaining('不含学习内容'), findsOneWidget);
    expect(find.textContaining('随机安装标识'), findsOneWidget);

    await tester.tap(find.text('关闭上报'));
    await tester.pumpAndSettle();
    expect(find.text('关于使用统计'), findsNothing);
  });

  testWidgets('看过说明之后再次启动不再弹出', (tester) async {
    final store = TelemetryStore(filesDir: directory.path);
    await tester.runAsync(() async {
      await store.markNoticeSeen();
      // 关掉上报，避免这次用例的后台请求留下等待中的定时器。
      await store.setEnabled(false);
    });

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const ZhixinApp());
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('关于使用统计'), findsNothing);
  });
}
