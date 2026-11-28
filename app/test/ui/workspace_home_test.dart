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
import 'package:zhixin/ui/now_page.dart';
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
    await tester.tap(find.byIcon(FLucideIcons.ellipsis));
    await settle(tester);
    await tester.tap(find.text('添加一页'));
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

  testWidgets('首页可浏览系统学习，并恢复上次学习位置', (tester) async {
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
      await scope!.testing.tasks.createItem(
        title: '独立推导一次差商极限',
        goalId: goal,
        conversationId: conversation,
        dueAt: scope!.timePolicy.now,
      );
      return plan.plan.id;
    });
    await tester.scrollUntilVisible(
      find.text('系统学习').first,
      120,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('系统学习').first.hitTestable());
    await settle(tester);
    expect(find.text('理解导数的定义'), findsOneWidget);
    expect(find.textContaining('下一步：从变化率理解导数'), findsOneWidget);
    await tester.tap(find.text('理解导数的定义'));
    await settle(tester);
    expect(find.byType(StudyPlanPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
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

  testWidgets('立即开始建议会保存进行中的事项与对话回执', (tester) async {
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

    await tester.ensureVisible(find.text('立即开始'));
    await tester.tap(find.text('立即开始').hitTestable());
    await settle(tester);
    await tester.tap(find.text('无归属').hitTestable());
    await settle(tester);
    final stored = await tester.runAsync(() => scope!.testing.tasks.items());
    expect(stored!.single.title, '再独立做一遍第 8 题');
    expect(stored.single.status, PlanItemStatus.doing);
    expect(find.text('已添加事项：再独立做一遍第 8 题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页把待办放在接下来', (tester) async {
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
}
