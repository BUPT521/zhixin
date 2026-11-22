import 'dart:io';

import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../application/discussion_service.dart';
import '../domain/models/chat_message.dart';
import '../domain/models/material.dart' show Citation;
import 'copy.dart';
import 'markdown_text.dart';
import 'workspace_widgets.dart';
import 'zhixin_toast.dart';

class DiscussionMessage extends StatelessWidget {
  const DiscussionMessage({
    super.key,
    required this.message,
    required this.imagePath,
    this.footer,
    this.onOpenCitation,
    this.highlighted = false,
  });
  final ChatMessage message;
  final String Function(String) imagePath;
  final ValueChanged<Citation>? onOpenCitation;

  /// 回答下方的补充操作，例如本地规则回答的配置与重新回答入口。
  final Widget? footer;

  /// 讨论内查找的当前一处：整条消息带底色与描边，切到下一处后随之消失。
  final bool highlighted;

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
            spacing: theme.space.sm,
            runSpacing: theme.space.sm,
            children: [
              for (final path in message.imagePaths)
                GestureDetector(
                  onTap: () => showImagePreview(context, imagePath(path)),
                  child: ClipRRect(
                    borderRadius: theme.radius.tag,
                    child: Image.file(
                      File(imagePath(path)),
                      width: 160,
                      height: 120,
                      cacheWidth: cacheWidth,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: theme.colors.surfaceContainerHigh,
                        child: SizedBox(
                          width: 160,
                          height: 120,
                          child: Center(
                            child: Text(
                              '本机没有这张原图',
                              style: theme.text.bodySmall.copyWith(
                                color: theme.colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        if (message.content.trim().isNotEmpty) ...[
          if (message.hasImages) SizedBox(height: theme.space.gap),
          MarkdownText(message.content, large: true),
        ],
      ],
    );
    final Widget body;
    if (message.role != MessageRole.assistant) {
      body = _bubble(context, isUser: message.isUser, child: content);
    } else {
      final citations = DiscussionService.citationsOf(message)
          .where((citation) => citation.quote.isNotEmpty);
      body = _replyCard(
        context,
        status: message.stopped
            ? '已停止生成'
            : message.interrupted
            ? '生成中断'
            : message.payload?.fromModel == false
            ? '本地规则'
            : null,
        statusTone: message.stopped
            ? TagTone.muted
            : message.interrupted
            ? TagTone.attention
            : TagTone.neutral,
        children: [
          content,
          if (citations.isNotEmpty) ...[
            SizedBox(height: theme.space.md),
            Divider(
              height: 1,
              thickness: 1,
              color: theme.colors.outlineVariant,
            ),
            SizedBox(height: theme.space.sm),
            Text('参考依据', style: theme.text.labelLarge),
            for (final (index, citation) in citations.indexed)
              _CitationTile(
                key: PageStorageKey((message.id, index)),
                citation: citation,
                onOpen:
                    onOpenCitation == null ||
                        citation.materialId.isEmpty ||
                        citation.pageNo <= 0
                    ? null
                    : () => onOpenCitation!(citation),
              ),
          ],
          ?footer,
        ],
      );
    }
    if (!highlighted) return body;
    // 查找跳转到的这一条：加一圈主色描边与浅底，不用改文字颜色或字体，
    // 切到下一处时旧标记随 [highlighted] 一起消失。
    return Container(
      decoration: BoxDecoration(
        color: theme.colors.primaryContainer.withValues(alpha: 0.35),
        borderRadius: theme.radius.card,
        border: Border.all(color: theme.colors.primary, width: 1.5),
      ),
      padding: EdgeInsets.all(theme.space.xs),
      child: body,
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
      margin: EdgeInsets.only(top: theme.space.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: theme.radius.control,
      ),
      child: forui.FAccordion(
        style: .delta(
          titlePadding: .value(
            EdgeInsets.symmetric(
              horizontal: theme.space.md,
              vertical: theme.space.sm,
            ),
          ),
          childPadding: .value(
            EdgeInsets.fromLTRB(
              theme.space.md,
              0,
              theme.space.md,
              theme.space.md,
            ),
          ),
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
                  size: 16,
                  color: citation.verified ? colors.primary : colors.error,
                ),
                SizedBox(width: theme.space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(citation.place, style: theme.text.titleSmall),
                      SizedBox(height: theme.space.xs / 2),
                      Text(
                        citation.verified ? '已核对' : '未能核对',
                        style: theme.text.bodySmall.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!citation.verified)
                  const InlineNotice(
                    message: '这段引文与材料原文对不上，标为未能核对；可以打开原文逐字对照。',
                  ),
                SelectionArea(
                  child: Text(citation.quote, style: theme.text.bodySmall),
                ),
              ],
            ),
          ),
          if (onOpen != null)
            forui.FButton(
              variant: forui.FButtonVariant.ghost,
              size: forui.FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: onOpen,
              child: const Text('打开材料原文'),
            ),
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
      context,
      children: [
        if (text.trim().isEmpty)
          Row(
            children: [
              const forui.FCircularProgress(size: .xs),
              SizedBox(width: context.zhixin.space.sm),
              Expanded(
                child: Text('正在回答', style: context.zhixin.text.bodySmall),
              ),
            ],
          )
        else
          MarkdownText(text, streaming: true, large: true),
      ],
    );
  }
}

Widget _replyCard(
  BuildContext context, {
  String? status,
  TagTone statusTone = TagTone.neutral,
  required List<Widget> children,
}) {
  final theme = context.zhixin;
  return DiscussionCard(
    margin: EdgeInsets.only(bottom: theme.space.md),
    icon: FLucideIcons.bookOpenText,
    title: '知新$buddyName',
    status: status,
    statusTone: statusTone,
    children: [
      Divider(height: 1, thickness: 1, color: theme.colors.outlineVariant),
      SizedBox(height: theme.space.sm),
      ...children,
    ],
  );
}

/// 回答、记忆、建议与回执共用卡片的标题、状态和边距。
///
/// 标题区的图标底与状态标签原先在这里手画，底色与字号和别处的
/// [LeadingIcon]、[StatusTag] 对不上；现在两处都改用共用组件。
class DiscussionCard extends StatelessWidget {
  const DiscussionCard({
    super.key,
    required this.margin,
    required this.icon,
    required this.title,
    required this.children,
    this.status,
    this.iconTone = TagTone.accent,
    this.statusTone = TagTone.neutral,
  });

  final EdgeInsetsGeometry margin;
  final IconData icon;
  final String title;
  final List<Widget> children;
  final String? status;
  final TagTone iconTone;
  final TagTone statusTone;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: margin,
      child: forui.FCard(
        child: Padding(
          padding: EdgeInsets.all(theme.space.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  LeadingIcon(icon, tone: iconTone, size: 32),
                  SizedBox(width: theme.space.sm),
                  Expanded(
                    child: Wrap(
                      spacing: theme.space.sm,
                      runSpacing: theme.space.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: theme.text.titleSmall),
                        if (status != null)
                          StatusTag(status!, tone: statusTone),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: theme.space.sm),
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
      margin: EdgeInsets.only(bottom: theme.space.sm),
      padding: EdgeInsets.symmetric(
        horizontal: theme.space.md,
        vertical: theme.space.md,
      ),
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

/// 点开一张本机原图看大图；消息里的图片与学习页的原题共用这一处。
///
/// [filePath] 是已经解析好的本机文件路径（应用私有目录里的绝对路径）。对话框
/// 默认限制宽度 280 到 560，看图时改成占满屏宽只留外边距，横屏与平板上不会被
/// 压窄；手机拍的原图直接解码要占几十 MB，按屏宽 × dpr × 2 设解码尺寸，与看图
/// 的 4 倍放大配合已经够清晰，大图解码之前先用同一张图的小尺寸垫底。
Future<void> showImagePreview(BuildContext context, String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) {
    if (!context.mounted) return;
    showToast(context, '这张原图在本机已经找不到');
    return;
  }
  if (!context.mounted) return;
  final media = MediaQuery.of(context);
  final size = media.size;
  final decodeWidth = (size.width * media.devicePixelRatio * 2).round();
  final thumbWidth = (size.width * media.devicePixelRatio).round();
  await forui.showFDialog<void>(
    context: context,
    builder: (context, style, animation) => forui.FDialog(
      animation: animation,
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        minWidth: 0,
        maxWidth: size.width - 24,
        maxHeight: size.height - 24,
      ),
      builder: (context, style) => InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: Image.file(
          file,
          cacheWidth: decodeWidth,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return Image.file(file, cacheWidth: thumbWidth);
          },
        ),
      ),
    ),
  );
}
