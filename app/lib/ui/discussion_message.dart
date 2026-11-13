import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../application/discussion_service.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/material.dart' show Citation;
import 'markdown_text.dart';

class DiscussionMessage extends StatelessWidget {
  const DiscussionMessage({
    super.key,
    required this.message,
    required this.imagePath,
    this.footer,
    this.onOpenCitation,
  });
  final ChatMessage message;
  final String Function(String) imagePath;
  final ValueChanged<Citation>? onOpenCitation;

  /// 回答下方的补充操作，例如本地规则回答的配置与重新回答入口。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    // 原图长边到 1600 像素，按显示宽度解码即可，一张能省下几 MB 内存。
    final theme = context.zhixin;
    final cacheWidth = (160 * MediaQuery.devicePixelRatioOf(context)).round();
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.hasImages)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final path in message.imagePaths)
                ClipRRect(
                  borderRadius: theme.radius.tag,
                  child: Image.file(
                    File(imagePath(path)),
                    width: 160,
                    height: 120,
                    cacheWidth: cacheWidth,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      width: 160,
                      height: 120,
                      child: Center(child: Text('本机没有这张原图')),
                    ),
                  ),
                ),
            ],
          ),
        if (message.content.trim().isNotEmpty) ...[
          if (message.hasImages) const SizedBox(height: 8),
          MarkdownText(message.content),
        ],
      ],
    );
    if (message.role != 'assistant') {
      return _bubble(context, isUser: message.isUser, child: content);
    }

    final citations = DiscussionService.citationsOf(message)
        .where((citation) => citation.quote.isNotEmpty);
    return _replyCard(
      status: message.stopped
          ? '已停止生成'
          : message.interrupted
          ? '生成中断'
          : message.structured?['model'] == false
          ? '本地规则'
          : null,
      children: [
        content,
        if (citations.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(height: 16),
          const SizedBox(height: 10),
          Text('参考依据', style: theme.text.labelLarge),
          for (final (index, citation) in citations.indexed)
            _CitationTile(
              key: PageStorageKey((message.id, index)),
              citation: citation,
              onOpen:
                  onOpenCitation == null ||
                      citation.materialId <= 0 ||
                      citation.pageNo <= 0
                  ? null
                  : () => onOpenCitation!(citation),
            ),
        ],
        ?footer,
      ],
    );
  }
}

class _CitationTile extends StatelessWidget {
  const _CitationTile({super.key, required this.citation, this.onOpen});

  final Citation citation;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final colors = theme.colors;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: forui.FAccordion(
        style: const .delta(
          titlePadding: .value(
            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          childPadding: .value(EdgeInsets.fromLTRB(10, 0, 10, 12)),
          dividerStyle: .delta(color: Colors.transparent),
        ),
        children: [
          forui.FAccordionItem(
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  citation.verified
                      ? FLucideIcons.badgeCheck
                      : FLucideIcons.circleHelp,
                  size: 18,
                  color: citation.verified ? colors.primary : colors.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(citation.place, style: theme.text.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        citation.verified ? '已核对' : '未能核对',
                        style: theme.text.bodySmall.copyWith(
                          color: citation.verified
                              ? colors.onSurfaceVariant
                              : colors.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            child: SelectionArea(
              child: Text(citation.quote, style: theme.text.bodySmall),
            ),
          ),
          if (onOpen != null)
            TextButton(onPressed: onOpen, child: const Text('打开材料原文')),
        ],
      ),
    );
  }
}

/// 还没有写入记录的回答：边生成边显示，完成后由正式消息替换。
class StreamingMessage extends StatelessWidget {
  const StreamingMessage({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _replyCard(
      children: [
        if (text.trim().isEmpty)
          Row(
            children: [
              const forui.FCircularProgress(size: .xs),
              const SizedBox(width: 8),
              Expanded(
                child: Text('正在回答', style: context.zhixin.text.bodySmall),
              ),
            ],
          )
        else
          MarkdownText(text, streaming: true),
      ],
    );
  }
}

Widget _replyCard({String? status, required List<Widget> children}) {
  return DiscussionCard(
    margin: const EdgeInsets.only(bottom: 12),
    icon: FLucideIcons.bookOpenText,
    title: '知新搭子',
    status: status,
    children: [
      const Divider(height: 16),
      const SizedBox(height: 10),
      ...children,
    ],
  );
}

/// 回答、记忆、建议与回执共用卡片的标题、状态和边距。
class DiscussionCard extends StatelessWidget {
  const DiscussionCard({
    super.key,
    required this.margin,
    required this.icon,
    required this.title,
    required this.children,
    this.status,
    this.accent,
  });

  final EdgeInsetsGeometry margin;
  final IconData icon;
  final String title;
  final List<Widget> children;
  final String? status;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final colors = theme.colors;
    final tone = accent ?? colors.primary;
    return Padding(
      padding: margin,
      child: forui.FCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: Icon(icon, size: 18, color: tone),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: theme.text.titleSmall),
                        if (status != null)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: tone.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              child: Text(
                                status!,
                                style: theme.text.labelSmall.copyWith(
                                  color: colors.onSurface,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

Widget _bubble(
  BuildContext context, {
  required bool isUser,
  required Widget child,
}) {
  final theme = context.zhixin;
  final side = BorderSide(color: theme.colors.outlineVariant);
  return Align(
    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      constraints: BoxConstraints(
        maxWidth:
            MediaQuery.sizeOf(context).width.clamp(0.0, theme.space.maxWidth) *
            0.82,
      ),
      decoration: BoxDecoration(
        color: isUser ? theme.colors.primaryContainer : theme.colors.card,
        borderRadius: BorderRadiusDirectional.only(
          topStart: theme.radius.card.topLeft,
          topEnd: theme.radius.card.topRight,
          bottomStart: theme.radius.card.bottomLeft,
          bottomEnd: isUser
              ? theme.radius.tag.bottomRight
              : theme.radius.card.bottomRight,
        ),
        border: isUser ? null : Border.fromBorderSide(side),
      ),
      child: child,
    ),
  );
}
