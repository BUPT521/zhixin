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

  testWidgets('未配置时本地回答给出步骤与配置入口，配置后可重新回答', (tester) async {
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

    // 本地回答针对刚输入的问题给步骤，卡片标明来源并给出配置入口。
    expect(find.textContaining('已知量和要求的量', findRichText: true), findsWidgets);
    expect(find.widgetWithText(forui.FButton, '配置模型'), findsOneWidget);

    // 从回答卡片直接进入设置页，配置页同时说明配置前后各能做什么。
    await tester.tap(find.widgetWithText(forui.FButton, '配置模型'));
    await waitFor(tester, find.text('设置'));
    // 设置页首读先放骨架，等模型段读完再核对说明。
    await waitFor(tester, find.textContaining('还没有配置模型'));

    await tester.enterText(
      find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byWidgetPredicate(
              (widget) => widget is EditableText && !widget.readOnly,
            ),
          )
          .at(2),
      'sk-test',
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
    await waitFor(tester, find.textContaining('模型配置已保存'));
    expect(storedSecret, contains('sk-test'));

    // 回到原来的讨论，同一个问题的本地回答下方换成用模型重新回答。
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await waitFor(tester, find.text('用模型重新回答'));
    expect(find.textContaining('解方程 3x+2=8', findRichText: true), findsWidgets);
    expect(find.widgetWithText(forui.FButton, '配置模型'), findsNothing);
  });

  testWidgets('模型调用失败时保留问题并给这次回答的重试入口', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 配置指向本机未监听端口：请求很快失败，不必等真实网络超时。
    storedSecret = jsonEncode({
      'api': 'chat',
      'base_url': 'http://127.0.0.1:1/v1',
      'model': 'test-model',
      'api_key': 'sk-test',
      'allow_images': '0',
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
    await waitFor(tester, find.text('重试这次回答'));

    // 用户消息已经落库，失败的一轮有自己的重试入口，不再只给配置入口。
    // 提示条与最后一条回答下方各有一个重试入口，两者都是 Forui 的按钮。
    expect(find.textContaining('模型调用失败', findRichText: true), findsWidgets);
    expect(find.widgetWithText(forui.FButton, '用模型重新回答'), findsNothing);
    expect(find.widgetWithText(forui.FButton, '重试这次回答'), findsWidgets);

    // 再失败一次也只补一条回答，不重复写用户消息。
    await tester.tap(find.text('重试这次回答'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      if (find.text('本地规则').evaluate().length >= 2) break;
    }
    expect(find.text('本地规则'), findsNWidgets(2));
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
