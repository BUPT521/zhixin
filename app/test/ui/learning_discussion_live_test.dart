import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/learning_page.dart';

import '../support/app_scope_teardown.dart';
import '../support/app_settle.dart';
import '../support/telemetry.dart';

/// 讨论页与学习页改成订阅之后，页面之外的写入由数据层重读（ADR-0014）。
///
/// 这里不返回记录页重进，也不点任何刷新入口：写入发生在页面之外，界面只靠
/// 订阅更新；原来的实现在这些地方要自己调用一次读取。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-learning-live-');
    await disableTelemetryForTests(directory.path);
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

  /// 轮询到目标控件出现：读取与回填都在后台完成，不能依赖 pumpAndSettle 收尾。
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    int rounds = 480,
  }) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 100));
      await advanceAsync(
        tester,
        scope?.testing.gate,
        const Duration(milliseconds: 20),
      );
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('等待界面出现超时：$finder');
  }

  /// 等后台读取与转圈收尾：数据库访问在应用根里排队，读没有结束就写库会等独占。
  Future<void> settle(WidgetTester tester) async {
    await settleFrames(tester, scope);
  }

  Future<void> openApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(const ZhixinApp());
      scope = tester.state<AppScopeState>(find.byType(AppScope));
      await scope!.ready;
    });
    await settle(tester);
  }

  Future<void> pushPage(WidgetTester tester, Widget page) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(MaterialPageRoute<void>(builder: (_) => page));
    await settle(tester);
  }

  testWidgets('讨论页跟随订阅显示页面之外追加的消息', (tester) async {
    await openApp(tester);
    final conversationId = (await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '订阅里的第一条消息');
      return result.userMessage.conversationId;
    }))!;
    await pushPage(tester, DiscussionPage(conversationId: conversationId));
    await pumpUntil(
      tester,
      find.textContaining('订阅里的第一条消息', findRichText: true),
    );

    // 页面之外再写一轮问答：消息列表由订阅重读，不需要返回记录页重进。
    await tester.runAsync(
      () => scope!.chat.discussion.reply(
        conversationId: conversationId,
        text: '页面之外追加的问题',
      ),
    );
    await pumpUntil(
      tester,
      find.textContaining('页面之外追加的问题', findRichText: true),
    );
    expect(tester.takeException(), isNull);
    // 让最后一次重读收尾，再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });

  testWidgets('学习页跟随订阅显示页面之外的提交', (tester) async {
    await openApp(tester);
    final questionId = (await tester.runAsync(
      () => scope!.chat.learning.capture(stem: '订阅里的题目'),
    ))!;
    await pushPage(tester, LearningPage(questionId: questionId));
    await pumpUntil(tester, find.text('作答草稿'));
    expect(find.text('未提交的草稿'), findsOneWidget);

    // 页面之外提交这次作答：历次尝试与草稿由订阅重读，页面不自己重新读取。
    await tester.runAsync(() async {
      final attempt = await scope!.chat.learning.openAttempt(questionId);
      await scope!.chat.learning.submit(
        attemptId: attempt.id,
        answer: '外部写下的答案',
        isCorrect: true,
        independent: true,
      );
    });
    await pumpUntil(tester, find.text('自评做对'));
    // 自评与模型判断改成状态标签，独立性在标签里也标出来。
    expect(find.text('独立完成'), findsWidgets);
    expect(find.textContaining('作答：外部写下的答案'), findsOneWidget);
    expect(find.text('未提交的草稿'), findsNothing);
    expect(tester.takeException(), isNull);
    // 让最后一次重读收尾，再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
  });
}
