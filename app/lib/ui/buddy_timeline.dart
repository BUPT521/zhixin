import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import '../application/buddy_actions.dart';
import '../application/discussion_service.dart';
import '../application/memory_view.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/material.dart' show Citation;
import 'buddy_flows.dart';
import 'copy.dart';
import 'discussion_cards.dart';
import 'discussion_message.dart';
import 'markdown_text.dart';
import 'theme.dart';

import '../domain/rules/text.dart';

/// 时间线里的一条内容。
///
/// 讨论页从记录消息生成，学习页从这次作答的帮助与最近讨论生成；两页的数据
/// 来源不同，共用的是同一套排列、记忆卡片、回执与失败说明。
sealed class BuddyTimelineEntry {
  const BuddyTimelineEntry();
}

/// 一条讨论消息。
class BuddyMessageEntry extends BuddyTimelineEntry {
  const BuddyMessageEntry({required this.message, this.footer});

  final ChatMessage message;

  /// 回答下方的恢复入口，例如配置模型或重新回答。
  final Widget? footer;
}

/// 正在生成的讨论回答。
class BuddyStreamingEntry extends BuddyTimelineEntry {
  const BuddyStreamingEntry(this.text);

  final ValueListenable<String> text;
}

/// 学习页这次求助的帮助：生成中显示流式正文，生成完显示已保存的正文。
class BuddyHelpEntry extends BuddyTimelineEntry {
  const BuddyHelpEntry({
    this.text,
    this.generating = false,
    required this.streaming,
  });

  final String? text;
  final bool generating;
  final ValueListenable<String> streaming;
}

/// 一条记忆卡片：待确认时可以记下或不记，已写入时可以撤销。
class BuddyMemoryEntry extends BuddyTimelineEntry {
  const BuddyMemoryEntry(this.item);

  final MemoryItemView item;
}

/// 一条还没有接受的下一步建议；只有讨论里会出现。
class BuddySuggestionEntry extends BuddyTimelineEntry {
  const BuddySuggestionEntry(this.suggestion);

  final PendingSuggestion suggestion;
}

/// 本次回答实际写入的改动，每条都可以单独撤销。
class BuddyChangesEntry extends BuddyTimelineEntry {
  const BuddyChangesEntry(this.changes);

  final List<AppliedChange> changes;
}

/// 一段说明：这一轮没有完成什么、已经保留了什么，以及可以怎么继续。
class BuddyNoticeEntry extends BuddyTimelineEntry {
  const BuddyNoticeEntry({required this.message, this.actions = const []});

  final String message;
  final List<Widget> actions;
}

/// 页面交给时间线的数据与操作。
///
/// 讨论页把记录里的消息、建议与回执填进来，学习页把未提交尝试上的帮助、
/// 记忆建议与最近讨论填进来；两页只需要实现取数与操作转发，排列与卡片样式
/// 由 [BuddyTimeline] 统一负责。
abstract class BuddyTimelineAdapter {
  /// 从旧到新的条目；[BuddyTimeline] 会按页面类型决定正向或倒序排列。
  List<BuddyTimelineEntry> get entries;

  /// 空时间线的说明；学习页始终有原题与草稿，不需要。
  Widget? get emptyState => null;

  /// 讨论页是一列可倒序滚动的消息，学习页是页面里的普通一列。
  bool get scrollable => false;

  bool get hasOlder => false;
  bool get loadingOlder => false;
  Future<void> loadOlder() async {}
  ScrollController? get controller => null;

  /// 讨论消息里的图片按应用私有目录解析。
  String imagePath(String stored);

  /// 讨论内查找的当前一处：这条消息高亮。
  bool isHighlighted(String messageId) => false;

  /// 当前一处消息的定位键；只有正在查找时需要，跳转靠它滚到屏幕外的那一条。
  Key? messageKey(String messageId) => null;

  /// 查找打开时把整列消息都建出来，滚动定位才能拿到屏幕外那条的上下文。
  bool get revealAll => false;

  /// 打开引用对应的材料原文；学习页的摘要不显示引用。
  void openCitation(Citation citation) {}

  void acceptMemory(MemoryItemView item);
  void dismissMemory(MemoryItemView item);
  void undoMemory(MemoryItemView item);

  /// 下一步建议与回执只有讨论页会出现；学习页不需要实现。
  void acceptSuggestion(
    PendingSuggestion suggestion, {
    bool schedule = false,
  }) {}
  void dismissSuggestion(PendingSuggestion suggestion) {}
  void undoChange(AppliedChange change) {}
}

/// 讨论与学习页共用的时间线。
///
/// 讨论页给出完整消息与倒序滚动，学习页给出帮助、记忆、回执与最近讨论；
/// 两页原先各写一遍条目拼接、记忆卡片操作与失败说明，改一处时另一处容易
/// 漏掉。现在由这里统一排列，页面只通过 [BuddyTimelineAdapter] 提供数据与
/// 操作。
class BuddyTimeline extends StatelessWidget {
  const BuddyTimeline({super.key, required this.adapter});

  final BuddyTimelineAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final entries = adapter.entries;
    if (adapter.scrollable) return _scrolling(context, entries);
    if (entries.isEmpty) return adapter.emptyState ?? const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final entry in entries) _entry(context, entry)],
    );
  }

  Widget _scrolling(BuildContext context, List<BuddyTimelineEntry> entries) {
    if (entries.isEmpty) {
      return adapter.emptyState ?? const SizedBox.shrink();
    }
    return ListView.builder(
      controller: adapter.controller,
      // 倒序列表把最新一条放在偏移 0，打开长讨论时直接落在底部。
      reverse: true,
      // 查找时要跳到屏幕外的消息：把列表整列建出来，定位键才有可用的上下文。
      scrollCacheExtent: adapter.revealAll
          ? const ScrollCacheExtent.pixels(_revealAllCacheExtent)
          : null,
      padding: EdgeInsets.symmetric(vertical: context.zhixin.space.md),
      itemCount: entries.length + (adapter.hasOlder ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == entries.length) return _olderFooter(context);
        // 倒序列表的逻辑顺序与新到旧相反，按条目倒着取。
        return _entry(context, entries[entries.length - 1 - index]);
      },
    );
  }

  /// 查找期间一次建出的列表长度上限：一次查找的讨论消息远小于这个高度。
  static const double _revealAllCacheExtent = 1000000;

  Widget _olderFooter(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.zhixin.space.md),
        child: adapter.loadingOlder
            ? const forui.FCircularProgress(size: .sm)
            : forui.FButton(
                variant: forui.FButtonVariant.ghost,
                mainAxisSize: MainAxisSize.min,
                onPress: adapter.loadOlder,
                child: const Text('读取较早讨论'),
              ),
      ),
    );
  }

  Widget _entry(BuildContext context, BuddyTimelineEntry entry) {
    final space = context.zhixin.space;
    return switch (entry) {
      BuddyMessageEntry(:final message, :final footer) => Padding(
        padding: EdgeInsets.symmetric(horizontal: space.page),
        child: DiscussionMessage(
          key: adapter.messageKey(message.id),
          message: message,
          imagePath: adapter.imagePath,
          footer: footer,
          highlighted: adapter.isHighlighted(message.id),
          onOpenCitation: adapter.openCitation,
        ),
      ),
      BuddyStreamingEntry(:final text) => Padding(
        padding: EdgeInsets.symmetric(horizontal: space.page),
        child: ValueListenableBuilder<String>(
          valueListenable: text,
          builder: (context, value, _) => StreamingMessage(text: value),
        ),
      ),
      BuddyHelpEntry() => _helpCard(context, entry),
      BuddyMemoryEntry(:final item) => Padding(
        padding: EdgeInsets.only(top: adapter.scrollable ? 0 : space.sm),
        child: MemoryCard(
          item: item,
          onAccept: () => adapter.acceptMemory(item),
          onDismiss: () => adapter.dismissMemory(item),
          onUndo: () => adapter.undoMemory(item),
        ),
      ),
      BuddySuggestionEntry(:final suggestion) => SuggestionCard(
        suggestion: suggestion,
        onAccept: () => adapter.acceptSuggestion(suggestion, schedule: false),
        onSchedule: () => adapter.acceptSuggestion(suggestion, schedule: true),
        onDismiss: () => adapter.dismissSuggestion(suggestion),
      ),
      BuddyChangesEntry(:final changes) => ChangeReceiptCard(
        changes: changes,
        onUndo: adapter.undoChange,
      ),
      BuddyNoticeEntry(:final message, :final actions) => Padding(
        padding: adapter.scrollable
            ? EdgeInsets.fromLTRB(space.page, space.tight, space.page, space.xs)
            : EdgeInsets.only(top: space.sm),
        child: FailureNotice(message: message, actions: actions),
      ),
    };
  }

  /// 学习页的帮助卡：生成中显示流式正文，生成完显示这一次保存的正文。
  ///
  /// 与回答、记忆、建议共用 [DiscussionCard]，帮助不再单独用陶土色底——这个
  /// 颜色只表示草稿与优先这类需要留意的状态。
  Widget _helpCard(BuildContext context, BuddyHelpEntry entry) {
    final theme = context.zhixin;
    if (!entry.generating && (entry.text?.trim().isEmpty ?? true)) {
      return const SizedBox.shrink();
    }
    return DiscussionCard(
      margin: EdgeInsets.only(top: theme.space.md),
      icon: FLucideIcons.lightbulb,
      title: '搭子的帮助',
      status: entry.generating ? '正在生成' : null,
      children: [
        if (entry.generating)
          ValueListenableBuilder<String>(
            valueListenable: entry.streaming,
            builder: (context, text, _) => text.trim().isEmpty
                ? Row(
                    children: [
                      const forui.FCircularProgress(size: .xs),
                      SizedBox(width: theme.space.sm),
                      Text('正在生成', style: theme.text.bodySmall),
                    ],
                  )
                : MarkdownText(text, streaming: true, large: true),
          )
        else
          MarkdownText(entry.text!, large: true),
      ],
    );
  }
}

/// 学习页底部的一条讨论摘要：只显示前两行，完整讨论另开。
class ChatMessagePreview extends StatelessWidget {
  const ChatMessagePreview({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final text = message.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = text.isEmpty
        ? (message.hasImages ? '[图片]' : '[空消息]')
        : truncateCodePoints(text, 80);
    return Padding(
      padding: EdgeInsets.only(top: context.zhixin.space.xs),
      child: Text(
        '${_roleLabel(message.role)}：$preview',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: context.zhixin.text.bodySmall,
      ),
    );
  }

  String _roleLabel(MessageRole role) => switch (role) {
    MessageRole.user => '你',
    MessageRole.assistant => buddyName,
    MessageRole.system => '系统',
    MessageRole.unknown => '系统',
  };
}
