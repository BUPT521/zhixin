import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 三栏与详情页共用的内容宽度：手机上铺满，平板与横屏上居中。
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: context.zhixin.space.maxWidth),
      child: child,
    ),
  );
}

/// 详情页内容与三栏采用相同的最大宽度。
class DetailScaffold extends StatelessWidget {
  const DetailScaffold({super.key, this.header, required this.child});

  final Widget? header;
  final Widget child;

  @override
  Widget build(BuildContext context) => forui.FScaffold(
    header: header,
    child: SafeArea(top: false, child: PageWidth(child: child)),
  );
}

/// 一节内容的标题：左侧标题与一句说明，右侧可放一个文字动作。
///
/// [first] 为真时去掉上方留白，用在页面第一节。说明只写这一节为什么这样
/// 排或怎么用，读者一看就懂的就不写。
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.first = false,
  });
  final String title;
  final String? subtitle;
  final Widget? action;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: EdgeInsets.only(
        top: first ? 0 : theme.space.section - theme.space.sm,
        bottom: theme.space.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: theme.text.titleMedium),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.text.bodySmall.copyWith(
                      color: theme.colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class ZhixinMark extends StatelessWidget {
  const ZhixinMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colors.primary,
        borderRadius: theme.radius.control,
      ),
      alignment: Alignment.center,
      child: Icon(
        FLucideIcons.bookOpen,
        size: size * 0.58,
        color: theme.colors.onPrimary,
      ),
    );
  }
}

/// 状态标签的语气：主色表示进行中或可继续，留意色表示草稿与优先，
/// 中性表示类别与归属，暗淡表示已结束或已取消。
enum TagTone { accent, attention, neutral, muted }

/// 一枚只表示状态的小标签，不接收点击；颜色只表达状态，不表达程度。
class StatusTag extends StatelessWidget {
  const StatusTag(
    this.label, {
    super.key,
    this.tone = TagTone.neutral,
    this.icon,
  });
  final String label;
  final TagTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final colors = theme.colors;
    final (background, foreground) = switch (tone) {
      TagTone.accent => (colors.primaryContainer, colors.primary),
      TagTone.attention => (
        colors.attentionContainer,
        colors.onAttentionContainer,
      ),
      TagTone.neutral => (colors.surfaceContainerHigh, colors.onSurface),
      TagTone.muted => (Colors.transparent, colors.onSurfaceVariant),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: theme.radius.tag,
        border: tone == TagTone.muted
            ? Border.all(color: colors.outlineVariant)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: foreground),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.text.labelMedium.copyWith(
                  color: foreground,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一行状态标签，放不下时换行。
class TagRow extends StatelessWidget {
  const TagRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: context.zhixin.space.xs + 2,
    runSpacing: context.zhixin.space.xs,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );
}

/// 列表卡片左侧的类型图标：浅底方块里放图标，进行中的用主色，已结束的暗淡。
class LeadingIcon extends StatelessWidget {
  const LeadingIcon(
    this.icon, {
    super.key,
    this.tone = TagTone.accent,
    this.size = 36,
  });
  final IconData icon;
  final TagTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final colors = theme.colors;
    final (background, foreground) = switch (tone) {
      TagTone.accent => (colors.primaryContainer, colors.onPrimaryContainer),
      TagTone.attention => (
        colors.attentionContainer,
        colors.onAttentionContainer,
      ),
      TagTone.neutral => (colors.surfaceContainerHigh, colors.onSurface),
      TagTone.muted => (colors.surfaceContainerHigh, colors.onSurfaceVariant),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: theme.radius.control,
      ),
      child: Icon(icon, size: 20, color: foreground),
    );
  }
}

/// 首页的次级入口，整张卡片可点。
class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return forui.FTile.raw(
      style: .delta(
        rawContentStyle: .delta(
          padding: .value(EdgeInsets.all(theme.space.md)),
        ),
      ),
      onPress: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              LeadingIcon(icon),
              Icon(
                FLucideIcons.arrowUpRight,
                size: 16,
                color: theme.colors.onSurfaceVariant,
              ),
            ],
          ),
          SizedBox(height: theme.space.sm),
          Text(title, style: theme.text.titleSmall),
          SizedBox(height: theme.space.xs),
          Text(
            subtitle,
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 没有内容时的说明：说清这里会放什么，并给出下一步。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: theme.space.xl,
        vertical: theme.space.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LeadingIcon(icon, size: 48),
          SizedBox(height: theme.space.md),
          Text(
            title,
            style: theme.text.titleMedium,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: theme.space.xs),
          Text(
            description,
            textAlign: TextAlign.center,
            style: theme.text.bodyMedium.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[SizedBox(height: theme.space.md), action!],
        ],
      ),
    );
  }
}

/// 某一段读取失败时就地说明保留状态与重试入口，不把整页换成一个错误。
class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colors.card,
          borderRadius: theme.radius.card,
          border: Border.all(color: theme.colors.error.withValues(alpha: 0.4)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  FLucideIcons.circleAlert,
                  size: 18,
                  color: theme.colors.error,
                ),
              ),
              SizedBox(width: theme.space.sm),
              Expanded(child: Text(message, style: theme.text.bodySmall)),
              if (onRetry != null)
                forui.FButton(
                  variant: forui.FButtonVariant.ghost,
                  size: forui.FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: onRetry,
                  child: Text(retryLabel),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 列表底部“读取更多”的统一样式：正在读时转圈，否则给一个文字按钮。
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({
    super.key,
    required this.label,
    required this.loading,
    required this.onPressed,
  });
  final String label;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: context.zhixin.space.md),
    child: Center(
      child: loading
          ? const forui.FCircularProgress(size: .sm)
          : forui.FButton(
              variant: forui.FButtonVariant.outline,
              size: forui.FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: onPressed,
              child: Text(label),
            ),
    ),
  );
}
