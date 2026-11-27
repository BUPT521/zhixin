import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/domain/models/study_plan.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/materials_page.dart';
import 'package:zhixin/ui/study_plan_page.dart';

import 'workspace_support.dart';

/// 安排页事项面板上的每个命令：状态命令真正落库，跳转命令真正打开目标页面。
///
/// 导航层与事项操作的改动之前先把现状写成用例，重构只换表达方式，行为按这里
/// 核对（docs/客户端实现审查与批次.md A33）。
void main() {
  registerWorkspaceTests();

  /// 建一份只有一步的系统学习计划，返回计划编号；这一步同时是安排页的一条事项。
  Future<String> addStudyPlan(WidgetTester tester) async {
    final id = await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '导数讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '导数描述函数在一点附近的变化率。',
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 1,
        pageTo: 1,
        steps: const [StudyStepDraft(title: '阅读导数定义', pageFrom: 1, pageTo: 1)],
      );
      return plan.plan.id;
    });
    await settle(tester);
    return id!;
  }

  Future<void> openPlanItems(WidgetTester tester) async {
    await tester.tap(find.text('安排').last);
    await settle(tester);
    await tester.tap(find.text('事项'));
    await settle(tester);
  }

  testWidgets('事项面板从这里打开它所属的学习计划', (tester) async {
    await openApp(tester);
    await addStudyPlan(tester);
    await openPlanItems(tester);

    await tester.tap(find.text('阅读导数定义'));
    await settle(tester);
    await tester.tap(find.text('打开学习计划'));
    await settle(tester);

    expect(find.byType(StudyPlanPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('学这一步按继续位置打开材料，并把步骤推进到进行中', (tester) async {
    await openApp(tester);
    final planId = await addStudyPlan(tester);
    await openPlanItems(tester);

    await tester.tap(find.text('阅读导数定义'));
    await settle(tester);
    await tester.tap(find.text('学这一步'));
    await settle(tester);

    expect(find.byType(MaterialDetailPage), findsOneWidget);
    final view = await tester.runAsync(
      () => scope!.study.systemPlan.view(planId),
    );
    expect(view!.steps.single.status, PlanItemStatus.doing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('事项面板的状态命令把事项改成进行中与已完成', (tester) async {
    await openApp(tester);
    final itemId = await tester.runAsync(
      () => scope!.testing.tasks.createItem(title: '整理错题'),
    );
    await settle(tester);
    await openPlanItems(tester);

    await tester.tap(find.text('整理错题'));
    await settle(tester);
    await tester.tap(find.text('标记进行中'));
    await settle(tester);
    var stored = await tester.runAsync(() => scope!.testing.tasks.items());
    expect(stored!.single.status, PlanItemStatus.doing);

    await tester.tap(find.text('整理错题'));
    await settle(tester);
    await tester.tap(find.text('完成事项'));
    await settle(tester);
    stored = await tester.runAsync(() => scope!.testing.tasks.items());
    expect(stored!.single.status, PlanItemStatus.done);
    expect(tester.takeException(), isNull);
    expect(itemId, isNotEmpty);
  });

  testWidgets('没有作答的事项从面板回到它的来源讨论', (tester) async {
    await openApp(tester);
    final conversationId = await tester.runAsync(() async {
      final id = await scope!.chat.discussion.createConversation(
        title: '为什么导数是变化率',
      );
      await scope!.testing.tasks.createItem(
        title: '回顾导数讨论',
        conversationId: id,
      );
      return id;
    });
    await settle(tester);
    await openPlanItems(tester);

    await tester.tap(find.text('回顾导数讨论'));
    await settle(tester);
    await tester.tap(find.text('回到原题'));
    await settle(tester);

    expect(
      tester.widget<DiscussionPage>(find.byType(DiscussionPage)).conversationId,
      conversationId,
    );
    expect(tester.takeException(), isNull);
  });
}
