import 'dart:convert';
import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ui/discussion_chat.dart';
import 'package:zhixin/ui/settings_page.dart';

import '../support/app_scope_teardown.dart';
import '../support/telemetry.dart';

/// 没有模型时的提问、配置与重答入口走同一条界面流程。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;
  String? storedSecret;

  setUpAll(() {});

  setUp(() async {
    storedSecret = null;
    directory = await Directory.systemTemp.createTemp('zhixin-local-reply-');
    await disableTelemetryForTests(directory.path);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final arguments = call.arguments as Map?;
        switch (call.method) {
          case 'read':
            return storedSecret;
          case 'write':
            storedSecret = arguments?['value'] as String?;
            return null;
          case 'delete':
            storedSecret = null;
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

  /// 轮询到目标控件出现：生成提示一直在动，不能依赖 pumpAndSettle 收尾。
  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    int rounds = 80,
  }) async {
    for (var i = 0; i < rounds; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时');
  }

  Future<void> clearToasts(WidgetTester tester) async {
    if (find.byType(forui.FToaster).evaluate().isEmpty) return;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('未登录时本地回答给出步骤与登录入口，登录之前不给重新回答', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(const ZhixinApp());
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await waitFor(tester, find.text('提出一个问题'));

    await tester.enterText(find.byType(EditableText).first, '解方程 3x+2=8，求 x');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('发送问题'));
    await waitFor(tester, find.text('本地规则'));
    await clearToasts(tester);

    // 本地回答针对刚输入的问题给步骤，卡片标明来源并给出登录入口。
    expect(find.textContaining('已知量和要求的量', findRichText: true), findsWidgets);
    expect(find.widgetWithText(forui.FButton, '登录后使用模型'), findsOneWidget);

    // 从回答卡片直接进入设置页，设置页说明模型要登录之后才能调用。
    await tester.tap(find.widgetWithText(forui.FButton, '登录后使用模型'));
    await waitFor(tester, find.text('设置'));
    // 设置页首读先放骨架，等模型段读完再核对说明。
    await waitFor(tester, find.textContaining('模型调用只用知新服务'));

    // 模型卡片只填模型名：地址与令牌由登录账号在运行时补上。
    await tester.enterText(
      find.descendant(
        of: find.byType(SettingsPage),
        matching: find.widgetWithText(forui.FTextField, '模型名'),
      ),
      'zhixin-chat',
    );
    // 设置页变长之后，直接 ensureVisible 会把按钮顶到页面头部下面；
    // 按居中位置滚动再点，避免点击落在头部区域。
    await Scrollable.ensureVisible(
      tester.element(find.text('保存')),
      alignment: 0.5,
    );
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    // 没有登录时保存不下来：模型只有知新服务一条路径，先让用户登录。
    await waitFor(tester, find.textContaining('登录'));
    expect(storedSecret, isNull, reason: '访问令牌与地址不写进本机配置');

    // 回到原来的讨论：仍然没有登录，恢复入口保持登录引导，不出现重新回答。
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await waitFor(tester, find.text('登录后使用模型'));
    expect(find.textContaining('解方程 3x+2=8', findRichText: true), findsWidgets);
    expect(find.widgetWithText(forui.FButton, '用模型重新回答'), findsNothing);
  });

  testWidgets('模型未登录时保留问题并给登录入口', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 模型配置只记模型名；测试环境里没有登录，模型调用因此失败，走失败分支。
    storedSecret = jsonEncode({
      'model': 'test-model',
      'allow_images': '1',
      'context_window_tokens': '65536',
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(const ZhixinApp());
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await waitFor(tester, find.text('提出一个问题'));

    await tester.enterText(find.byType(EditableText).first, '解方程 3x+2=8，求 x');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('发送问题'));
    await waitFor(tester, find.text('本地规则'));

    // 用户消息已经落库；没有登录时模型调用发不出去，恢复入口只有登录。
    // 提示条与最后一条回答下方各有入口，两者都是 Forui 的按钮。
    await waitFor(tester, find.widgetWithText(forui.FButton, '登录后使用模型'));
    expect(find.widgetWithText(forui.FButton, '用模型重新回答'), findsNothing);
    expect(find.widgetWithText(forui.FButton, '重试这次回答'), findsNothing);

    // 未登录时点入口先进设置页；关掉之后回到讨论，回答与问题都没有变化。
    await tester.tap(find.widgetWithText(forui.FButton, '登录后使用模型').first);
    await waitFor(tester, find.text('设置'));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await waitFor(tester, find.text('登录后使用模型'));
    expect(find.text('本地规则'), findsOneWidget);

    // 首页的记录卡也会显示这个问题；这里只看讨论页里的用户消息只有一条。
    expect(
      find.descendant(
        of: find.byType(DiscussionChat),
        matching: find.text('解方程 3x+2=8，求 x'),
      ),
      findsOneWidget,
    );
  });
}
