import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 三栏与详情页共用的内容宽度：手机上铺满，平板与横屏上按页面宽度居中。
///
/// 最大宽度包含两侧的页面边距，屏上的内容字行因此不比手机上更宽，标题栏、
/// 卡片与底栏的左右边界也与内容一致，不随着屏幕变宽各自贴着两边。
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final space = context.zhixin.space;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: space.maxWidth + space.page * 2),
        child: child,
      ),
    );
  }
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

/// 记录与安排共用的页框：上面一条搜索入口，下面一行为分段页签，再下面放当前
/// 页签的内容。
///
/// 两页的边距与页签位置因此只写一份：换页签时搜索框与页签不移动，内容只在下面
/// 换；二级入口没有共用的搜索时传空，页签直接接在标题栏下面。
class TabbedPageFrame extends StatelessWidget {
  const TabbedPageFrame({
    super.key,
    this.searchField,
    required this.tabBar,
    required this.child,
  });

  /// 搜索入口；为空表示这一页没有共用的搜索，不留出这一行。
  final Widget? searchField;

  /// 分段页签，由页面给出。
  final Widget tabBar;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return PageWidth(
      child: Column(
        children: [
          if (searchField != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.space.page,
                theme.space.xs,
                theme.space.page,
                theme.space.md,
              ),
              child: searchField,
            ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: theme.space.page),
            child: tabBar,
          ),
          SizedBox(height: theme.space.sm),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 三栏页面（现在、记录、安排）的骨架。
///
/// 三栏外面还有一层带底栏的 [forui.FScaffold]，键盘弹出时它已经按键盘高度把
/// 内容区缩小了一次；页面自己的骨架若再缩一次，内容高度会被扣掉两个键盘高度，
/// 输入区与发送按钮因此被裁掉，键盘上方只剩一条空白。所以这里固定不再按键盘
/// 缩放，需要弹出键盘的详情页仍用 [DetailScaffold] 的默认行为。
class TabScaffold extends StatelessWidget {
  const TabScaffold({super.key, this.header, required this.child});

  final Widget? header;
  final Widget child;

  @override
  Widget build(BuildContext context) => forui.FScaffold(
    header: header,
    resizeToAvoidBottomInset: false,
    child: child,
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
        top: first ? 0 : theme.space.sectionTop,
        // 动作的可点区域本身就有 [SectionLink.height] 高，下方少留一档。
        bottom: action is SectionLink ? theme.space.sm : theme.space.md,
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

/// 区块标题右侧的文字动作：只有主色文字（可带小图标），不画按钮。
///
/// 可点区域高 [height]，比 44 的按钮矮一截，一行标题不再被动作撑高；两侧各外扩
/// 半个内边距，可点在 44 见方以内，而文字与标题栏动作的图标、版心右边界对齐。
class SectionLink extends StatelessWidget {
  const SectionLink({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  static const double height = 40;
  static const double _hitPadding = 10;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final color = onPressed == null
        ? theme.colors.onSurfaceVariant
        : theme.colors.primary;
    return Transform.translate(
      offset: const Offset(_hitPadding, 0),
      child: forui.FTappable.static(
        onPress: onPressed,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _hitPadding),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: color),
                  SizedBox(width: theme.space.xs),
                ],
                Text(
                  label,
                  style: theme.text.labelLarge.copyWith(
                    fontSize: 12.5,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 品牌标记：应用图标上的那株幼苗，颜色与应用图标、启动页一致。
///
/// 图形取自 `android/.../ic_launcher_foreground.xml` 与启动页的
/// `ic_splash_sprout.xml`（108 见方的视口）：叶片与茎用品牌蓝的深浅两档，土块取
/// 同一颜色的三成半透明。标记固定为品牌蓝，不随主题色切换，与手机上的应用图标
/// 对得上。
class ZhixinMark extends StatelessWidget {
  const ZhixinMark({super.key, this.size = 36});

  /// 幼苗的高度；宽度按图形比例约为它的 0.72。
  final double size;

  @override
  Widget build(BuildContext context) {
    final brightness = forui.FTheme.of(context).colors.brightness;
    final ink = ZhixinAccent.blue.primaryFor(brightness);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SproutPainter(ink: ink, soil: ink.withValues(alpha: 0.35)),
      ),
    );
  }
}

/// 应用图标里的幼苗：两片叶、茎与土块，路径与启动图标的矢量文件一致。
class _SproutPainter extends CustomPainter {
  const _SproutPainter({required this.ink, required this.soil});

  final Color ink;
  final Color soil;

  /// 幼苗在 108 视口里的包围盒；缩放时以它的中心对齐标记中心。
  static const Rect _bounds = Rect.fromLTRB(33.75, 26, 74.25, 82);

  static final Path _leftLeaf = Path()
    ..moveTo(53.75, 45)
    ..cubicTo(43.75, 45, 36.75, 39, 35.75, 30)
    ..cubicTo(45.75, 30, 52.75, 36, 53.75, 45)
    ..close();

  static final Path _rightLeaf = Path()
    ..moveTo(53.75, 44)
    ..cubicTo(64.75, 44, 72.75, 37, 74.25, 26)
    ..cubicTo(62.75, 26, 54.75, 33, 53.75, 44)
    ..close();

  static final Path _stem = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(51.75, 43, 55.75, 66),
        const Radius.circular(2),
      ),
    );

  static final Path _soil = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(33.75, 63, 73.75, 82),
        const Radius.circular(4.5),
      ),
    );

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / _bounds.height;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-_bounds.center.dx, -_bounds.center.dy);
    final paint = Paint()..color = ink;
    canvas.drawPath(_leftLeaf, paint);
    canvas.drawPath(_rightLeaf, paint);
    canvas.drawPath(_stem, paint);
    paint.color = soil;
    canvas.drawPath(_soil, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SproutPainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.soil != soil;
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
        // 竖向 2 是标签与文字之间的光学微调，横向取 space.sm。
        padding: EdgeInsets.symmetric(horizontal: theme.space.sm, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: foreground),
              SizedBox(width: theme.space.xs),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.text.labelMedium.copyWith(color: foreground),
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
    spacing: context.zhixin.space.tight,
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
          padding: .value(
            EdgeInsets.symmetric(
              horizontal: kCardInset,
              vertical: theme.space.md,
            ),
          ),
        ),
      ),
      onPress: onTap,
      // 一行一个入口：左图标，中间标题与说明，右箭头。
      child: Row(
        children: [
          LeadingIcon(icon),
          SizedBox(width: theme.space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.text.titleSmall),
                Text(
                  subtitle,
                  style: theme.text.bodySmall.copyWith(
                    color: theme.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            FLucideIcons.chevronRight,
            size: 16,
            color: theme.colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// 没有内容时的说明：说清这里会放什么，并给出下一步。内容区的左右留白与
/// 列表项同取 [kCardInset]，说明文字与列表里的文字从同一处起排。
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
        horizontal: kCardInset,
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

/// 列表为空时的一张说明卡：列表里的一行换成 [EmptyState]，外面套上与列表项
/// 同一种圆角和描边的卡片。
///
/// 外面再包一层撑满宽度的盒子，放在可滚动的列表里时不会按文字的固有宽度缩窄；
/// 记录、材料、事项与目标四类列表的空态因此同宽、同位置。
class EmptyCard extends StatelessWidget {
  const EmptyCard({
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
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: forui.FCard(
      child: EmptyState(
        icon: icon,
        title: title,
        description: description,
        action: action,
      ),
    ),
  );
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
          padding: EdgeInsets.fromLTRB(
            theme.space.md,
            theme.space.md,
            theme.space.sm,
            theme.space.sm,
          ),
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

/// 同一张卡片里两组内容之间的分隔线：1 像素高，上下各留一档间距。
///
/// 设置页、引导页与购买面板原先各写一份同样的 `Padding` 加 `ColoredBox`；
/// 默认上下各留 `space.md`，紧凑的分组传 `space.sm`。线色取
/// [ZhixinColors.outlineVariant]，与卡片、列表项的描边同一档。
class CardDivider extends StatelessWidget {
  const CardDivider({super.key, this.gap});

  /// 上下各留的间距；为空时取 `space.md`。
  final double? gap;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: gap ?? theme.space.md),
      child: SizedBox(
        height: 1,
        child: ColoredBox(color: theme.colors.outlineVariant),
      ),
    );
  }
}

/// 一次操作之后的说明：失败用带可选重试的就地说明，成功用一行小字。
///
/// 账号页、云端备份页、我的页与设置页原先各自拼这两种呈现，连间距也各写一份；
/// 页面只保存消息、是否失败与可选的重试动作，由这里决定用哪一种。
/// [failed] 为真时通过 [InlineNotice] 显示，[onRetry] 为空就没有重试按钮。
class ResultNotice extends StatelessWidget {
  const ResultNotice({
    super.key,
    required this.message,
    this.failed = false,
    this.onRetry,
  });

  final String message;
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    if (failed) return InlineNotice(message: message, onRetry: onRetry);
    return Padding(
      padding: EdgeInsets.only(bottom: theme.space.sm),
      child: Text(message, style: theme.text.bodySmall),
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

/// 没有版面可以占位的等待所用的圈：应用启动、相机预览与照片解码。
///
/// 页面首读一律用 [ListSkeleton]，读完原位换成内容；只有上面这三处等待的
/// 内容还没有形状，才居中转圈。
///
/// 圈定在 [diameter]：Forui 的 `FCircularProgress` 默认取正文字号，手机上只有
/// 18，看上去只是一个图标，读不出“正在读取”。按钮、列表行与照片上的指示仍用
/// `sm`、`xs`，大小跟着所在控件走，只有这类整屏等待放大并取主色。
class PageLoading extends StatelessWidget {
  const PageLoading({super.key});

  /// 圆的直径，与 Material 圆形进度条的默认直径一致，两种组件互换时页面
  /// 的分量相当。
  static const double diameter = 36;

  @override
  Widget build(BuildContext context) => Center(
    child: forui.FCircularProgress(
      style: .delta(
        iconStyle: .delta(size: diameter, color: context.zhixin.colors.primary),
      ),
    ),
  );
}

/// 首读时的占位骨架：几张与真实卡片同高的静态卡片，读完原位换成内容。
///
/// 卡片里按高度摆出标题、正文与标签的灰条，看上去是一张还没填字的卡片，
/// 而不是一个空框；每张的条长略有不同，几张叠在一起不像复制出来的。
/// 不做闪光或呼吸动画：动效口径里不循环，而且不断变化的占位更妨碍阅读。
/// 高度固定，替换前后页面高度不变，下面的内容不会跟着移动。
class ListSkeleton extends StatelessWidget {
  const ListSkeleton({
    super.key,
    this.rows = 3,
    this.rowHeight = 88,
    this.padding = EdgeInsets.zero,
  });

  final int rows;
  final double rowHeight;
  final EdgeInsetsGeometry padding;

  /// 各张卡片的条长（占卡片内宽的比例）：标题、第一行正文、第二行正文。
  static const _widths = [
    (0.46, 0.92, 0.64),
    (0.62, 0.78, 0.5),
    (0.38, 0.86, 0.72),
  ];
  static const _titleHeight = 14.0;
  static const _lineHeight = 10.0;
  static const _tagHeight = 18.0;
  static const _tagWidth = 56.0;
  static const _lineGap = 10.0;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    // 矮卡片收紧上下内边距，至少留得下标题与一行正文。
    final vertical = rowHeight < 80 ? theme.space.md : theme.space.lg;
    final inner = rowHeight - vertical * 2;
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var row = 0; row < rows; row++)
            Padding(
              padding: EdgeInsets.only(bottom: theme.space.sm),
              child: Semantics(
                label: '正在读取',
                child: Container(
                  height: rowHeight,
                  padding: EdgeInsets.symmetric(
                    horizontal: theme.space.lg,
                    vertical: vertical,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colors.card,
                    borderRadius: theme.radius.card,
                    border: Border.all(color: theme.colors.outlineVariant),
                  ),
                  child: ExcludeSemantics(
                    child: _bars(theme, _widths[row % _widths.length], inner),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 按卡片内高从上往下摆条：标题、正文、第二行正文、标签，放不下的不摆。
  Widget _bars(
    ZhixinTheme theme,
    (double, double, double) widths,
    double inner,
  ) {
    final (title, body, second) = widths;
    final candidates = [
      (_titleHeight, title, null),
      (_lineHeight, body, null),
      (_lineHeight, second, null),
      (_tagHeight, null, _tagWidth),
    ];
    final bars = <Widget>[];
    var used = 0.0;
    for (final (height, factor, width) in candidates) {
      final needed = height + (bars.isEmpty ? 0 : _lineGap);
      if (used + needed > inner) break;
      used += needed;
      if (bars.isNotEmpty) bars.add(const SizedBox(height: _lineGap));
      final bar = DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(width == null ? 4 : height / 2),
        ),
      );
      bars.add(
        SizedBox(
          height: height,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: width == null
                ? FractionallySizedBox(
                    widthFactor: factor,
                    heightFactor: 1,
                    child: bar,
                  )
                : SizedBox(width: width, height: height, child: bar),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: bars,
    );
  }
}
