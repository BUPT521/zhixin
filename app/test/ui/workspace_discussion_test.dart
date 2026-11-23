import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/domain/models/chat_message.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
import 'package:zhixin/domain/models/material.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/ui/discussion_page.dart';
import 'package:zhixin/ui/learning_page.dart';
import 'package:zhixin/ui/now_page.dart';
import 'package:zhixin/ui/records_page.dart';
import 'package:zhixin/ui/zhixin_chip.dart';

import 'workspace_support.dart';

void main() {
  registerWorkspaceTests();

  testWidgets('从记录打开讨论再返回，筛选与首页输入都不重置', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final goal = await scope!.testing.tasks.createGoal(title: '概率练习');
      final conversation = await scope!.testing.conversations.create(
        title: '待结束的讨论',
        goalId: goal,
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.user,
        content: '从记录里打开这条讨论',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.assistant,
        content: '返回之后记录仍然刷新',
      );
    });
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .first,
      '保留这个问题',
    );
    tester.testTextInput.hide();
    await tester.tap(
      find.descendant(
        of: find.byType(forui.FBottomNavigationBar),
        matching: find.text('记录'),
      ),
    );
    await settle(tester);

    // 先按目标筛选，返回后用它判断记录页有没有被换掉重建。
    ZhixinChip goalChip() => tester.widget<ZhixinChip>(
      find.ancestor(of: find.text('概率练习'), matching: find.byType(ZhixinChip)),
    );
    await tester.tap(find.text('概率练习'));
    await settle(tester);
    expect(goalChip().selected, isTrue);

    await tester.tap(find.text('待结束的讨论'));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    await tester.tap(discussionMoreMenu());
    await settle(tester);
    await tester.tap(find.text('结束讨论'));
    await settle(tester);
    expect(find.text('已结束'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.byType(RecordsPage), findsOneWidget);
    // 内容刷新：记录状态已经改过；界面状态保留：目标筛选还在原处。
    expect(
      find.descendant(of: find.byType(RecordsPage), matching: find.text('已结束')),
      findsOneWidget,
    );
    expect(goalChip().selected, isTrue);

    await tester.tap(
      find.descendant(
        of: find.byType(forui.FBottomNavigationBar),
        matching: find.text('现在'),
      ),
    );
    await settle(tester);
    expect(find.text('保留这个问题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长讨论按需构建，打开时停在最新一条', (tester) async {
    await openApp(tester);
    final id = await tester.runAsync(() async {
      final conversation = await scope!.testing.conversations.create(
        title: '长讨论',
      );
      for (var index = 0; index < 60; index++) {
        await scope!.testing.conversations.append(
          conversation,
          role: index.isEven ? MessageRole.user : MessageRole.assistant,
          content: '第 $index 条消息',
        );
      }
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

    expect(find.text('第 59 条消息', findRichText: true), findsOneWidget);
    expect(find.text('第 0 条消息', findRichText: true), findsNothing);

    // 滚到最早的一端，滚动监听加载更早的一页后再滚到新的最早一端。
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await settle(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await settle(tester);
    expect(find.text('第 0 条消息', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('回答、记忆和建议卡片保留各自的操作', (tester) async {
    await openApp(tester, size: const Size(390, 900));
    final id = await tester.runAsync(() async {
      final conversation = await scope!.testing.conversations.create(
        title: '条件概率',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.user,
        content: '为什么条件概率要除以条件事件的概率？',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.assistant,
        content:
            '### 先缩小范围\n\n已知 B 发生时，只在 B 的范围内看 A。'
            '分子计算两件事同时发生的概率，分母将 B 的概率重新归一化。',
        payload: const ChatMessagePayload(
          fromModel: true,
          citations: [
            Citation(
              materialId: 'mat-1',
              materialTitle: '概率论讲义',
              pageNo: 7,
              quote: '条件概率是已知一个事件发生时，另一个事件发生的概率。',
              verified: true,
            ),
          ],
          memoryItems: [
            // 记忆建议卡片按类别、来源与有效期显示，类别是三分类之一。
            MemoryDraft(
              id: 'memory-1',
              kind: MemoryKind.semantic,
              content: '讲解概率时先用具体例子。',
              source: MemorySource.inferred,
            ),
          ],
          nextSteps: [
            ChatNextStep(
              id: 's1',
              title: '用抽球问题练习条件概率',
              action: '分别写出已知条件与要求的事件。',
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

    expect(find.text('参考依据'), findsOneWidget);
    expect(find.text('记忆建议'), findsOneWidget);
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('下一步建议'), findsOneWidget);
    expect(find.text('约 10 分钟'), findsOneWidget);
    await preview(tester, 'model-cards');

    // 点“记下”之后记忆按语义标签写进库，卡片改为已记下并给出撤销。
    await tester.tap(find.text('记下'));
    await settle(tester);
    expect(find.text('已记下'), findsOneWidget);
    expect(find.text('待确认'), findsNothing);
    expect(find.text('撤销'), findsOneWidget);

    final dismiss = find.widgetWithText(forui.FButton, '暂不安排');
    await tester.ensureVisible(dismiss);
    await tester.tap(dismiss);
    await settle(tester);
    final history = await tester.runAsync(
      () => scope!.chat.discussion.history(id!),
    );
    expect(history!.last.payload?.dismissedTitles, {'用抽球问题练习条件概率'});
    await tester.pumpAndSettle();
    expect(find.text('下一步建议'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新问题独立保存，已有讨论保持原样，返回后可继续', (tester) async {
    await openApp(tester);
    final oldId = await tester.runAsync(
      () => scope!.chat.discussion.createConversation(title: '原有讨论'),
    );
    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .first,
      '导数的定义是什么',
    );
    await tester.tap(find.bySemanticsLabel('发送问题'));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('导数的定义是什么'), findsOneWidget);
    final records = await tester.runAsync(
      () => scope!.chat.discussion.records(),
    );
    expect(records, hasLength(2));
    expect(records!.first.id, isNot(oldId));
    final original = await tester.runAsync(
      () => scope!.chat.discussion.history(oldId!),
    );
    expect(original, isEmpty);
    expect(tester.takeException(), isNull);
    await preview(tester, 'discussion');
    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.byType(NowPage), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('导数的定义是什么'),
      180,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('导数的定义是什么'));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('结束讨论只改记录状态，发消息重新打开', (tester) async {
    await openApp(tester);
    final id = await tester.runAsync(() async {
      final conversation = await scope!.testing.conversations.create(
        title: '待结束的讨论',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.user,
        content: '这条讨论要结束',
      );
      await scope!.testing.conversations.append(
        conversation,
        role: MessageRole.assistant,
        content: '结束后仍可继续',
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

    await tester.tap(discussionMoreMenu());
    await settle(tester);
    await tester.tap(find.text('结束讨论'));
    await settle(tester);
    expect(find.byType(forui.FDialog), findsNothing);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('已结束'), findsOneWidget);
    expect(find.text('结束讨论'), findsNothing);
    final ended = await tester.runAsync(() => scope!.chat.discussion.byId(id!));
    expect(ended!.open, isFalse);

    await tester.enterText(
      find
          .byWidgetPredicate(
            (widget) => widget is EditableText && !widget.readOnly,
          )
          .last,
      '再问一句',
    );
    await tester.tap(find.byIcon(FLucideIcons.arrowUp));
    await settle(tester);
    final reopened = await tester.runAsync(
      () => scope!.chat.discussion.byId(id!),
    );
    expect(reopened!.open, isTrue);
    expect(find.text('已结束'), findsNothing);
    await tester.tap(discussionMoreMenu());
    await settle(tester);
    expect(find.text('结束讨论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('继续上次按最近一次学习排序，并给出草稿与下一步', (tester) async {
    await openApp(tester);
    await tester.runAsync(() async {
      final material = await scope!.library.material.create(
        title: '概率论讲义',
        kind: MaterialKind.book,
      );
      await scope!.library.material.addPage(
        materialId: material,
        pageNo: 1,
        content: '条件概率是已知一个事件发生时，另一个事件发生的概率。',
      );
      await scope!.study.systemPlan.createPlan(
        materialId: material,
        pageFrom: 1,
        pageTo: 1,
        title: '读完条件概率',
        steps: const [
          StudyStepDraft(title: '阅读条件概率的定义', pageFrom: 1, pageTo: 1),
        ],
      );
      final questionId = await scope!.chat.learning.capture(stem: '写出条件概率公式');
      final view = await scope!.chat.learning.view(questionId);
      await scope!.testing.attempts.saveDraft(
        view.openAttempt!.id,
        answer: '先写出 P(A|B)=P(AB)/P(B)',
      );
    });
    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('现在').last);
    await settle(tester);

    expect(find.text('写出条件概率公式'), findsOneWidget);
    expect(find.textContaining('上次写于'), findsOneWidget);
    expect(find.textContaining('写到了：先写出 P(A|B)=P(AB)/P(B)'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('读完条件概率'),
      160,
      scrollable: find
          .descendant(
            of: find.byType(NowPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('下一步：阅读条件概率的定义'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('讨论里可以开始作答，题目沿用首条内容', (tester) async {
    await openApp(tester);
    final conversationId = await tester.runAsync(() async {
      final result = await scope!.chat.discussion.reply(text: '第 8 题求条件概率');
      return result.userMessage.conversationId;
    });
    final id = conversationId!;

    await tester.tap(find.text('记录').last);
    await settle(tester);
    await tester.tap(find.text('第 8 题求条件概率').first);
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('开始作答'), findsOneWidget);

    await tester.tap(find.text('开始作答'));
    await settle(tester);
    expect(find.byType(LearningPage), findsOneWidget);
    expect(find.text('第 8 题求条件概率'), findsOneWidget);

    final view = await tester.runAsync(() => scope!.chat.learning.view(id));
    expect(view!.question.conversationId, id);
    expect(view.question.stem, '第 8 题求条件概率');
    expect(view.attempts.single.helps, isEmpty);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.byType(DiscussionPage), findsOneWidget);
    expect(find.text('继续作答'), findsOneWidget);
    final sessions = await tester.runAsync(
      () => scope!.testing.studyRecords.recent(),
    );
    expect(sessions!.single.endedAt, isNotNull);

    await tester.tap(find.byKey(const ValueKey('zhixin-header-back')));
    await settle(tester);
    expect(find.widgetWithText(forui.FTile, '第 8 题求条件概率'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('records-search-entry')));
    await settle(tester);
    await tester.enterText(editableFields(), '条件概率');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(find.widgetWithText(forui.FTile, '第 8 题求条件概率'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
