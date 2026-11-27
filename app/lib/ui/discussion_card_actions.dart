import 'package:flutter/widgets.dart';

import '../app_scope.dart';
import '../application/buddy_actions.dart';
import '../application/discussion_service.dart';
import '../application/memory_view.dart';
import 'buddy_flows.dart';
import 'discussion_stream.dart';
import 'failure_feedback.dart';
import 'navigation.dart';
import 'undo_feedback.dart';
import 'zhixin_toast.dart';

/// 讨论页的卡片操作：开始作答、下一步建议、记忆卡片与改动回执。
///
/// 页面原来把这些流程与 State 的 setState 写在一起，建议、记忆与回执各自拼
/// 失败说明；现在收进一个普通控制器，页面只保留确认框（选择目标）与渲染。
/// 每一步的说明仍由 [describeFailure] 写，控制器只把结果交回页面的提示位。
class DiscussionCardActions {
  DiscussionCardActions({
    required this.stream,
    required this.onChanged,
    required this.showNotice,
  });

  /// 开始作答的等待标志与生成状态在流式回答控制器里，与发送共用输入区的按钮。
  final DiscussionStream stream;

  /// 等待状态变了让页面重建。
  final VoidCallback onChanged;

  /// 失败说明交给页面的提示位。
  final void Function(String notice) showNotice;

  /// 从这条讨论开始作答：以当时最后一条用户消息为原题，作答挂在这条记录上。
  Future<void> startAnswering(
    BuildContext context,
    String conversationId,
  ) async {
    if (stream.answering) return;
    stream.answering = true;
    onChanged();
    try {
      final questionId = await AppScope.of(context).chat.learning
          .startAnswering(conversationId: conversationId);
      if (!context.mounted) return;
      await openLearning(context, questionId);
    } catch (error, stack) {
      if (!context.mounted) return;
      showNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '打开作答',
          kind: 'discussion_start_answer',
          kept: '讨论与作答记录没有改动',
          next: '可以再试一次',
        ),
      );
    } finally {
      stream.answering = false;
      if (context.mounted) onChanged();
    }
  }

  /// 接受一条下一步建议；归属已经由页面选好。
  Future<void> acceptSuggestion(
    BuildContext context, {
    required String conversationId,
    required PendingSuggestion suggestion,
    required String? goalId,
    required bool start,
  }) async {
    try {
      final result = await AppScope.of(context).chat.discussion.acceptNextStep(
        conversationId: conversationId,
        messageId: suggestion.messageId,
        draft: suggestion.draft,
        stepId: suggestion.stepId,
        goalId: goalId,
        start: start,
      );
      if (!context.mounted) return;
      showActionToast(
        context,
        start ? '事项已开始' : '已保存为学习事项',
        label: '查看事项',
        onPressed: () => openPlanDetail(context, result.item.id),
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      showNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '保存这条学习事项',
          kind: 'discussion_accept_step',
          kept: '建议还在讨论里',
          next: '可以再试一次',
        ),
      );
    }
  }

  /// 收起一条建议：只改记录状态，不删除消息。
  Future<void> dismissSuggestion(
    BuildContext context, {
    required String conversationId,
    required PendingSuggestion suggestion,
  }) async {
    try {
      await AppScope.of(context).chat.discussion.dismissNextStep(
        conversationId: conversationId,
        messageId: suggestion.messageId,
        title: suggestion.draft.title,
        stepId: suggestion.stepId,
      );
    } catch (error, stack) {
      if (!context.mounted) return;
      showNotice(
        describeFailure(
          context,
          error,
          stack,
          action: '收起这条建议',
          kind: 'discussion_dismiss_step',
          kept: '建议还在讨论里',
          next: '可以再试一次',
        ),
      );
    }
  }

  /// 撤销一次写入；回执里的每条改动都走这里。
  Future<void> undoChange(BuildContext context, AppliedChange change) =>
      undoCommitWithFeedback(context, change.commitId);

  /// 记忆卡片与撤销之后由订阅更新页面，公共流程里的这次重读不再发起。
  Future<void> acceptMemory(
    BuildContext context, {
    required String conversationId,
    required MemoryItemView item,
  }) async {
    final messageId = item.messageId;
    if (messageId == null) return;
    await acceptMemoryCard(
      context: context,
      accept: () => AppScope.of(context).chat.discussion.acceptMemoryItem(
        conversationId: conversationId,
        messageId: messageId,
        itemId: item.itemId,
      ),
      scope: 'discussion',
      showNotice: showNotice,
    );
  }

  Future<void> dismissMemory(
    BuildContext context, {
    required String conversationId,
    required MemoryItemView item,
  }) async {
    final messageId = item.messageId;
    if (messageId == null) return;
    await dismissMemoryCard(
      context: context,
      dismiss: () => AppScope.of(context).chat.discussion.dismissMemoryItem(
        conversationId: conversationId,
        messageId: messageId,
        itemId: item.itemId,
      ),
      scope: 'discussion',
      showNotice: showNotice,
    );
  }

  Future<void> undoMemory(
    BuildContext context, {
    required MemoryItemView item,
  }) async {
    final commitId = item.commitId;
    if (commitId == null) return;
    await undoMemoryCard(
      context: context,
      commitId: commitId,
      scope: 'discussion',
      showNotice: showNotice,
    );
  }
}
