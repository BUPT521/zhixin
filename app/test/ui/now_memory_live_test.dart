import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zhixin/app.dart';
import 'package:zhixin/app_scope.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';
import 'package:zhixin/ui/memory_page.dart';
import 'package:zhixin/ui/memory_proposal_page.dart';
import 'package:zhixin/ui/study_plan_page.dart';

import '../support/telemetry.dart';

/// 订阅跟随写入更新（ADR-0014）：首页摘要、记忆、记忆建议与系统学习四页。
///
/// 写入走 [seed]：真异步区里写库，随后 pump 到回填结束。重读在发出通知的
/// 执行区里跑，因此与写入同一条事件循环排队，不会与页面测试的假异步互等。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  AppScopeState? scope;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('zhixin-live-');
    await disableTelemetryForTests(directory.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });

  tearDown(() async {
    await scope?.testing.db.close();
    scope = null;
    await directory.delete(recursive: true);
  });

  /// 推进到所有读取、回填与过渡动画结束。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  /// 在真异步区里写库，再 pump 到订阅的重读回填完成。
  Future<T> seed<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    await settle(tester);
    return result as T;
  }

  Future<void> openApp(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
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

  testWidgets('首页摘要跟随写入更新，不需要手动重读', (tester) async {
    await openApp(tester, size: const Size(390, 2400));
    expect(find.text('随时回来继续学习'), findsOneWidget);

    final conversationId = await seed(tester, () async {
      final id = await scope!.chat.discussion.createConversation(title: '条件概率');
      await scope!.testing.conversations.append(
        id,
        role: MessageRole.user,
        content: '为什么条件概率要除以条件事件发生的概率？',
      );
      return id;
    });
    expect(conversationId, isNotEmpty);
    expect(find.text('条件概率'), findsOneWidget);
    expect(find.textContaining('上次问：为什么条件概率'), findsOneWidget);
    expect(find.text('随时回来继续学习'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记忆页在保存与删除之后跟随订阅更新', (tester) async {
    await openApp(tester);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(MaterialPageRoute<void>(builder: (_) => const MemoryPage()));
    await settle(tester);
    expect(find.byType(MemoryPage), findsOneWidget);
    expect(find.text('还没有学习记忆'), findsOneWidget);
    expect(find.textContaining('搭子会在使用中逐步记住'), findsOneWidget);

    await seed(
      tester,
      () => scope!.memory.edit.add(
        kind: MemoryKind.preference,
        content: '先给提示，再看完整解答',
      ),
    );
    expect(find.text('先给提示，再看完整解答'), findsOneWidget);
    expect(find.text('偏好'), findsWidgets);

    final memories = (await tester.runAsync(() => scope!.memory.edit.list()))!;
    // 编辑框里改过类型也要真正保存：内容不变、类型变了同样形成一次修改。
    await seed(
      tester,
      () => scope!.memory.edit.save(
        memories.single,
        kind: MemoryKind.constraint,
        content: '先给一步提示，再给完整解答',
      ),
    );
    expect(find.text('先给提示，再看完整解答'), findsNothing);
    expect(find.text('先给一步提示，再给完整解答'), findsOneWidget);
    expect(find.text('限制'), findsWidgets);
    expect(find.text('偏好'), findsNothing);

    await seed(tester, () => scope!.memory.edit.delete(memories.single.id));
    expect(
      find.text('先给一步提示，再给完整解答'),
      findsNothing,
      reason: '已删除的条目不再列在记忆页，也不再提供修改与删除',
    );
    expect(find.text('已删除的记忆可在数据版本里查看。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记忆建议页的记录列表跟随写入更新', (tester) async {
    await openApp(tester);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const MemoryProposalPage()),
    );
    await settle(tester);
    expect(find.text('还没有可以整理的作答'), findsOneWidget);

    final conversationId = await seed(
      tester,
      () => scope!.chat.learning.capture(stem: '写出条件概率公式'),
    );
    expect(find.text('最近有作答的记录'), findsOneWidget);
    expect(find.text('写出条件概率公式'), findsOneWidget);

    // 提交一次作答：列表随作答与记忆相关的表重读，判断跟着更新。
    await seed(tester, () async {
      final view = await scope!.chat.learning.view(conversationId);
      await scope!.chat.learning.submit(
        attemptId: view.openAttempt!.id,
        answer: 'P(A|B)=P(AB)/P(B)',
        isCorrect: true,
        independent: false,
      );
    });
    expect(find.text('写出条件概率公式'), findsOneWidget);
    expect(find.text('未判断'), findsNothing);

    // 点一条记录，整理结果就在这条记录下方展开，不再追加到整页最下面。
    await tester.tap(find.text('写出条件概率公式'));
    await settle(tester);
    expect(find.textContaining('不记为独立表现'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统学习页在推进步骤之后跟随订阅更新', (tester) async {
    await openApp(tester);
    final created = await seed(tester, () async {
      final materialId = await scope!.library.material.create(
        title: '概率论讲义',
        kind: MaterialKind.book,
      );
      await scope!.library.material.addPage(
        materialId: materialId,
        pageNo: 1,
        content: '条件概率是已知一个事件发生时另一个事件发生的概率。',
      );
      return scope!.study.systemPlan.createPlan(
        materialId: materialId,
        pageFrom: 1,
        pageTo: 1,
        steps: const [
          StudyStepDraft(title: '阅读条件概率的定义', pageFrom: 1, pageTo: 1),
        ],
      );
    });

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => StudyPlanPage(planId: created.plan.id),
      ),
    );
    await settle(tester);
    // 步骤标题与状态在系统学习页重排过，这里只核对这一条步骤与它的状态标签。
    expect(find.textContaining('阅读条件概率的定义'), findsWidgets);
    expect(find.text('待学'), findsOneWidget);

    await seed(
      tester,
      () => scope!.study.systemPlan.setStepStatus(
        created.plan.id,
        created.steps.single.id,
        PlanItemStatus.done,
      ),
    );
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('待学'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
