import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../application/buddy_actions.dart';
import '../application/discussion_service.dart';
import '../application/memory_view.dart';
import '../domain/models/buddy_protocol.dart';
import '../domain/rules/time_format.dart';
import 'discussion_message.dart';

/// 讨论里三类卡片共用的外边距：与消息列同宽，左右各留 16。
const discussionCardMargin = EdgeInsets.fromLTRB(16, 4, 16, 4);

/// 一条记忆：待确认时给出“记下”与“不记”，已经写入时给出“撤销”。
///
/// 卡片只负责展示与转发操作，写入、忽略与撤销仍由讨论页调用用例层完成。
class MemoryCard extends StatelessWidget {
  const MemoryCard({
    super.key,
    required this.item,
    required this.onAccept,
    required this.onDismiss,
    required this.onUndo,
  });

  final MemoryItemView item;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final draft = item.draft;
    final pending = item.pending;
    final source = draft.source == MemorySource.user ? '你说的' : '模型推断';
    final valid = draft.validUntil == null
        ? '长期有效'
        : '有效至 ${formatDate(draft.validUntil!)}';
    return DiscussionCard(
      margin: discussionCardMargin,
      icon: pending ? FLucideIcons.bookmarkPlus : FLucideIcons.bookmark,
      title: pending ? '记忆建议' : '已记下',
      status: pending ? '待确认' : null,
      accent: pending ? theme.colors.secondary : null,
      children: [
        Text(draft.content, style: theme.text.bodyMedium),
        const SizedBox(height: 4),
        Text(
          '${draft.kind.label} · $source · $valid',
          style: theme.text.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (pending) ...[
              forui.FButton(
                variant: forui.FButtonVariant.secondary,
                mainAxisSize: MainAxisSize.min,
                onPress: onAccept,
                child: const Text('记下'),
              ),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: onDismiss,
                child: const Text('不记'),
              ),
            ] else
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: item.commitId == null ? null : onUndo,
                child: const Text('撤销'),
              ),
          ],
        ),
      ],
    );
  }
}

/// 一条还没有接受的下一步建议；接受时由讨论页选择归属并创建学习事项。
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({
    super.key,
    required this.suggestion,
    required this.onAccept,
    required this.onSchedule,
    required this.onDismiss,
  });

  final PendingSuggestion suggestion;
  final VoidCallback onAccept;
  final VoidCallback onSchedule;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final draft = suggestion.draft;
    final minutes = draft.minutes;
    return DiscussionCard(
      margin: discussionCardMargin,
      icon: FLucideIcons.calendarClock,
      title: '下一步建议',
      status: minutes != null && minutes > 0 ? '约 $minutes 分钟' : null,
      children: [
        Text(draft.title, style: theme.text.titleSmall),
        if (draft.action != null)
          Text('要做的事：${draft.action}', style: theme.text.bodySmall),
        if (draft.endCondition != null)
          Text('结束条件：${draft.endCondition}', style: theme.text.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            forui.FButton(
              variant: forui.FButtonVariant.secondary,
              mainAxisSize: MainAxisSize.min,
              onPress: onAccept,
              child: const Text('保存为学习事项'),
            ),
            forui.FButton(
              variant: forui.FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: onSchedule,
              child: const Text('保存并选时间'),
            ),
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: onDismiss,
              child: const Text('暂不安排'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 本次回答实际写入的改动，每条都可以单独撤销。
class ChangeReceiptCard extends StatelessWidget {
  const ChangeReceiptCard({
    super.key,
    required this.changes,
    required this.onUndo,
  });

  final List<AppliedChange> changes;
  final ValueChanged<AppliedChange> onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return DiscussionCard(
      margin: discussionCardMargin,
      icon: FLucideIcons.circleCheck,
      title: '改动回执',
      children: [
        for (final (index, change) in changes.indexed) ...[
          if (index > 0) const Divider(height: 16),
          Row(
            children: [
              Expanded(child: Text(change.text, style: theme.text.bodySmall)),
              forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: () => onUndo(change),
                child: const Text('撤销'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
