import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/context_request.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/study.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/learning_page.dart';
import 'package:zhixin/ui/materials_page.dart';
import 'package:zhixin/ui/now_page.dart';
import 'package:zhixin/ui/plan_page.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/study_plan_page.dart';
import 'package:zhixin/ui/zhixin_segmented.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('添加一页遇到已有页码时不覆盖，提示到详情更正', (tester) async {
    await openApp(tester);
    final materialId = await tester.runAsync(() async {
      final id = await scope!.library.material.create(title: '概率论讲义');
      await scope!.library.material.addPage(
        materialId: id,
        pageNo: 1,
        content: '已经校对过的原文',
      );
      return id;
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(
      find.widgetWithText(ZhixinSegmented<RecordsTab>, '材料').hitTestable(),
    );
    await settle(tester);
    await tester.tap(find.byIcon(FLucideIcons.filePlus));
    await settle(tester);

    final fields = find.descendant(
      of: find.byType(forui.FDialog),
      matching: editableFields(),
    );
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '1');
    await tester.enterText(fields.at(2), '后来粘贴的原文');
    await tester.tap(find.text('保存').last);
    await settle(tester);
    expect(find.textContaining('第 1 页已有原文'), findsOneWidget);

    await tester.tap(find.text('取消').last);
    await settle(tester);
    final pages = await tester.runAsync(
      () => scope!.library.material.pages(materialId!),
    );
    expect(pages!.single.content, '已经校对过的原文');
    expect(tester.takeException(), isNull);
  });

  testWidgets('过期记忆单独标出且不参与回答上下文', (tester) async {
    await openApp(tester);
    // 先用记忆页的新增写一条语义记忆，再把有效期改到昨天，使它成为过期条目。
    await tester.runAsync(() async {
      await scope!.memory.edit.add(
        kind: MemoryKind.semantic,
        content: '本周只有半小时可用于复习',
      );
      await updateRow(scope!.testing.db, 'memory', {
        'valid_until': DateTime.now()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      });
    });
    await tester.tap(find.byIcon(FLucideIcons.brain));
    await settle(tester);
    expect(find.text('已过期'), findsOneWidget);
    expect(find.text('本周只有半小时可用于复习'), findsOneWidget);
    final memories = await tester.runAsync(
      () async =>
          (await scope!.chat.context.load(const ContextRequest())).memories,
    );
    expect(
      memories!.any((memory) => memory.content == '本周只有半小时可用于复习'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页只推荐有效安排，并恢复系统学习的原位置', (tester) async {
    await openApp(tester);
    final planId = await tester.runAsync(() async {
      final goal = await scope!.testing.tasks.createGoal(title: '高等数学 · 导数与微分');
      final material = await scope!.library.material.create(
        title: '微积分学习讲义',
        kind: MaterialKind.text,
        goalId: goal,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数与变化率',
      );
      final conversation = await scope!.chat.discussion.createConversation(
        title: '如何理解导数的几何意义',
        materialId: material,
        pageNo: 3,
        goalId: goal,
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 3,
        pageTo: 3,
        title: '理解导数的定义',
        steps: const [
          StudyStepDraft(title: '从变化率理解导数', pageFrom: 3, pageTo: 3),
        ],
      );
      final now = scope!.timePolicy.now;
      // 三条安排都放在今天且不跨零点；只有最后一条仍在进行。
      final base = now.subtract(const Duration(minutes: 1));
      final states = ['done', 'cancelled', 'valid'];
      for (var index = 0; index < states.length; index++) {
        final state = states[index];
        final item = await scope!.testing.tasks.createItem(
          title: state == 'valid' ? '独立推导一次差商极限' : '已结束的安排',
          goalId: goal,
          conversationId: conversation,
          note: '说明极限存在的条件',
          estMinutes: 20,
        );
        final start = base.subtract(Duration(minutes: (2 - index) * 30));
        final block = await scope!.testing.schedule.addBlock(
          planItemId: item,
          start: start,
          end: start.add(const Duration(minutes: 20)),
        );
        if (state == 'done') {
          await scope!.study.plan.setStatus(item, PlanItemStatus.done);
        }
        if (state == 'cancelled') {
          await scope!.testing.schedule.setBlockStatus(
            block,
            ScheduleBlockStatus.cancelled,
          );
        }
      }
      final activity = await scope!.chat.context.loadActivity();
      expect(activity.ongoing!.item.title, '独立推导一次差商极限');
      final week = scope!.timePolicy.naturalWeekRange(now);
      // 这一步的安排只用来验证安排列表与跳转，时刻固定成本周某一天的 08:00。
      // 选离“现在”最远的那一天，是因为上面三条安排围着 now，按 now 前后 20 分钟
      // 检查时间段：放在本周第一天（通常是周一）时，UTC 的 CI 恰好在周一 08:00
      // 前后跑测试就会撞上那三条，报时间段冲突。
      final firstMorning = week.start.add(const Duration(hours: 8));
      final lastMorning = week.start.add(const Duration(days: 6, hours: 8));
      final scheduledAt =
          firstMorning.difference(now).abs() >=
              lastMorning.difference(now).abs()
          ? firstMorning
          : lastMorning;
      await scope!.testing.schedule.addBlock(
        planItemId: plan.steps.single.id,
        start: scheduledAt,
        end: scheduledAt.add(const Duration(minutes: 20)),
      );
      return plan.plan.id;
    });
    await tester.tap(find.text('安排').last);
    await settle(tester);
    final initialPlanList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('理解导数的定义'),
      120,
      scrollable: initialPlanList,
    );
    await preview(tester, 'plan-populated');
    expect(find.text('理解导数的定义'), findsOneWidget);
    expect(find.textContaining('下一步：从变化率理解导数'), findsOneWidget);
    final scheduledStep = find.text('从变化率理解导数');
    final planList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(scheduledStep, -120, scrollable: planList);
    // 已预约的学习步骤写出所属计划，开始与结束时刻在左侧上下排列。
    final scheduledTile = find.ancestor(
      of: scheduledStep,
      matching: find.byType(forui.FTile),
    );
    expect(
      find.descendant(of: scheduledTile, matching: find.text('所属计划：理解导数的定义')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: scheduledTile, matching: find.text('08:00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: scheduledTile, matching: find.text('08:20')),
      findsOneWidget,
    );
    await tester.tap(scheduledStep.hitTestable());
    await settle(tester);
    await tester.tap(find.text('打开学习计划').hitTestable());
    await settle(tester);
    expect(find.byType(StudyPlanPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    await tester.tap(find.text('现在').last);
    await settle(tester);
    await preview(tester, 'now-populated');
    await tester.scrollUntilVisible(
      find.text('理解导数的定义'),
      160,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(find.text('理解导数的定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('理解导数的定义').hitTestable());
    await settle(tester);
    expect(find.text('从变化率理解导数'), findsOneWidget);
    final view = await tester.runAsync(
      () => scope!.study.systemPlan.view(planId!),
    );
    expect(view!.plan.currentPage, 3);
    expect(tester.takeException(), isNull);
    await preview(tester, 'study-plan');
  });

  testWidgets('贴一道题只发图片时可以先存讨论，文字才带出处', (tester) async {
    await openApp(tester, size: const Size(363, 792));
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('贴一道题'));
    await settle(tester);

    final dialog = find.byType(forui.FDialog);
    expect(dialog, findsOneWidget);
    // 没有文字也没有图片时不能保存；只有图片时也不显示出处与摘录。
    final empty = tester.widget<forui.FButton>(
      find.widgetWithText(forui.FButton, '保存'),
    );
    expect(empty.onPress, isNull);
    expect(find.text('出处（可选）'), findsNothing);

    await tester.enterText(
      find.descendant(of: dialog, matching: editableFields()).first,
      '求条件概率',
    );
    await settle(tester);
    expect(find.text('出处（可选）'), findsOneWidget);
    final filled = tester.widget<forui.FButton>(
      find.widgetWithText(forui.FButton, '保存'),
    );
    expect(filled.onPress, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('接受下一步建议时可以直接选定时间', (tester) async {
    await openApp(tester);
    final id = await tester.runAsync(() async {
      final conversation = await scope!.testing.conversations.create(
        title: '再练一次',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.user,
        content: '第 8 题又做错了，怎么办',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.assistant,
        content: '先收下这条安排，再自己独立做一遍。',
        payload: const ChatMessagePayload(
          nextSteps: [
            ChatNextStep(
              id: 's1',
              title: '再独立做一遍第 8 题',
              action: '合上笔记重新做一遍。',
              minutes: 10,
            ),
          ],
        ),
      );
      return conversation;
    });
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiscussionPage(conversationId: id),
      ),
    );
    await settle(tester);

    await tester.ensureVisible(find.text('保存并选时间'));
    await tester.tap(find.text('保存并选时间').hitTestable());
    await settle(tester);
    await tester.tap(find.text('无归属').hitTestable());
    await settle(tester);
    expect(find.text('预约学习时间'), findsOneWidget);
    await tester.tap(find.widgetWithText(forui.FButton, '预约').hitTestable());
    await settle(tester);

    final stored = await tester.runAsync(() async {
      final items = await scope!.testing.tasks.items();
      final blocks = await scope!.testing.schedule.blocksForItem(
        items.single.id,
      );
      return (items: items, blocks: blocks);
    });
    expect(stored!.items.single.title, '再独立做一遍第 8 题');
    expect(stored.blocks, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页把正在进行的预约直接打开到材料页', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '导数讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数描述函数在一点附近的变化率。',
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 3,
        pageTo: 3,
        title: '导数练习计划',
        steps: const [StudyStepDraft(title: '理解导数的定义', pageFrom: 3, pageTo: 3)],
      );
      final now = scope!.timePolicy.now;
      final dayStart = scope!.timePolicy.naturalDate(now);
      final fiveMinutesAgo = now.subtract(const Duration(minutes: 5));
      final start = fiveMinutesAgo.isBefore(dayStart)
          ? dayStart
          : fiveMinutesAgo;
      await scope!.testing.schedule.addBlock(
        planItemId: plan.steps.single.id,
        start: start,
        end: start.add(const Duration(minutes: 20)),
      );
      scope!.dataVersion.value++;
    });
    await settle(tester);

    expect(find.text('正在进行'), findsOneWidget);
    expect(find.textContaining('正在进行 · '), findsOneWidget);
    await tester.tap(find.text('开始学习'));
    await settle(tester);
    expect(find.byType(MaterialDetailPage), findsOneWidget);
    expect(find.textContaining('本次范围：第 3 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页把没有预约的待办放在接下来', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.testing.tasks.createItem(title: '整理错题', estMinutes: 25);
      scope!.dataVersion.value++;
    });
    await settle(tester);

    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('待开始 · 约 25 分钟'), findsOneWidget);
    expect(find.text('整理错题'), findsOneWidget);
    expect(find.text('查看事项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页按记录去重，有草稿的题目只出现一次并直达作答', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      await scope!.chat.learning.capture(stem: '首页去重题目');
      scope!.dataVersion.value++;
    });
    await settle(tester);

    expect(find.text('首页去重题目'), findsOneWidget);
    await tester.tap(find.text('首页去重题目'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预约可以直接打开这一步的材料，结束预约不推进计划', (tester) async {
    await openApp(tester);
    final data = await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '导数讲义',
        kind: MaterialKind.text,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 3,
        content: '导数描述函数在一点附近的变化率。',
      );
      final plan = await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 3,
        pageTo: 3,
        steps: const [StudyStepDraft(title: '理解导数的定义', pageFrom: 3, pageTo: 3)],
      );
      final step = plan.steps.single;
      final start = scope!.timePolicy.now.subtract(const Duration(minutes: 5));
      final block = await scope!.testing.schedule.addBlock(
        planItemId: step.id,
        start: start,
        end: start.add(const Duration(minutes: 20)),
      );
      return (stepId: step.id, blockId: block, planId: plan.plan.id);
    });
    await tester.tap(find.text('安排').last);
    await settle(tester);
    final planList = find
        .descendant(
          of: find.byType(PlanPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('理解导数的定义'),
      120,
      scrollable: planList,
    );
    await tester.tap(find.text('理解导数的定义').hitTestable());
    await settle(tester);
    await tester.tap(find.text('学这一步').hitTestable());
    await settle(tester);
    expect(find.byType(MaterialDetailPage), findsOneWidget);
    expect(find.textContaining('本次范围：第 3 页'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.textContaining('最近预约：'), findsOneWidget);

    await tester.ensureVisible(find.text('理解导数的定义').hitTestable());
    await tester.tap(find.text('理解导数的定义').hitTestable());
    await settle(tester);
    await tester.tap(find.text('结束本次预约').hitTestable());
    await settle(tester);
    await tester.tap(
      find.widgetWithText(forui.FButton, '结束本次预约').hitTestable(),
    );
    await settle(tester);

    final after = await tester.runAsync(() async {
      return (
        step: await scope!.testing.tasks.byId(data!.stepId),
        block: await scope!.testing.schedule.blockById(data.blockId),
        plan: await scope!.study.systemPlan.view(data.planId),
      );
    });
    expect(after!.step!.status, PlanItemStatus.doing);
    expect(after.block!.status, ScheduleBlockStatus.done);
    expect(after.plan.plan.stepsDone, 0);
    // 结束预约后安排页会再读一次周日程；等这次读取收尾再关闭测试库。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    expect(tester.takeException(), isNull);
  });
}
