import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 一组互斥的视图切换，例如记录里的“学习记录 / 材料”与安排里的四个页签。
///
/// 等宽时选中底色是一块，切换时沿整条平移；窄屏或放大文字时按内容宽度横向
/// 滚动。整条与按钮、输入框同高 [ZhixinSpace.controlHeight]；每一项按下去时
/// 放大几个百分点，松开或切换之后回位，当前项再按一次没有动作，不放大，选中
/// 底色也不跟着放大。
class ZhixinSegmented<T> extends StatelessWidget {
  const ZhixinSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<ZhixinSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  static const _trackPadding = 3.0;
  static const _iconSize = 16.0;
  static const _iconSpacing = 6.0;

  /// 等分一项时扣掉的横向内边距：左右各 10。窄屏上四个中文页签能等分排下，
  /// 不因为两三个像素的余量退回滚动排布。
  static const _slotInsets = 20.0;

  /// 窄屏滚动时一项的最小宽度：等分放不下时才取这一档，每一项不低于
  /// 一行的可点宽度。
  static const _slotMinWidth = 56.0;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    final labelStyle = theme.text.labelLarge.copyWith(
      fontWeight: FontWeight.w600,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = segments.length;
        final slotWidth = (constraints.maxWidth - 2 * _trackPadding) / count;
        // 窄屏或放大文字时放不下：整条不设最小高度、按内容宽度横向滚动，
        // 每一项仍留够可点宽度，超出整条的部分用户横向划过去。
        final tight = !constraints.hasBoundedWidth || slotWidth < _slotMinWidth;
        final fits =
            !tight &&
            slotWidth >= _slotMinWidth &&
            _labelsFit(context, labelStyle, slotWidth - _slotInsets);
        final children = [
          for (final segment in segments)
            _segment(context, theme, segment, labelStyle, expand: fits),
        ];
        final index = segments.indexWhere((s) => s.value == selected);
        final row = Row(
          mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
          children: children,
        );
        // 容器内边距 3 是滑块与轨道之间的光学间隙，属于微调，不占令牌档位。
        final Widget track = Container(
          padding: const EdgeInsets.all(_trackPadding),
          decoration: BoxDecoration(
            color: theme.colors.surfaceContainerHigh,
            borderRadius: theme.radius.control,
          ),
          child: fits && index >= 0
              ? Stack(
                  children: [
                    // 选中底色只有一块，切换时按整条等宽的目标位置平移：旧位置的
                    // 底色先滑走再停到新的一项下面，不会新旧两块同时淡入淡出，也
                    // 不会出现字样已经换了、底色还留在上一项的情况。
                    Positioned.fill(
                      child: IgnorePointer(
                        child: LayoutBuilder(
                          builder: (context, track) => AnimatedAlign(
                            duration: context.motionOf(theme.motion.standard),
                            curve: theme.motion.move,
                            alignment: AlignmentDirectional(
                              count == 1 ? 0 : -1 + 2 * index / (count - 1),
                              0,
                            ),
                            child: SizedBox(
                              width: track.maxWidth / count,
                              height: double.infinity,
                              child: _thumb(theme),
                            ),
                          ),
                        ),
                      ),
                    ),
                    row,
                  ],
                )
              : row,
        );
        return Semantics(
          container: true,
          child: fits
              // 整条与按钮、输入框同高：每一项的可点区域跟着撑满这一档。
              ? ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: ZhixinSpace.controlHeight,
                  ),
                  child: track,
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: track,
                ),
        );
      },
    );
  }

  bool _labelsFit(BuildContext context, TextStyle style, double width) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    );
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    final labelStyle = MediaQuery.boldTextOf(context)
        ? resolved.copyWith(fontWeight: FontWeight.bold)
        : resolved;
    final fits = segments.every((segment) {
      painter.text = TextSpan(text: segment.label, style: labelStyle);
      painter.layout();
      final iconWidth = segment.icon == null ? 0.0 : _iconSize + _iconSpacing;
      return painter.width + iconWidth <= width;
    });
    painter.dispose();
    return fits;
  }

  Widget _thumb(ZhixinTheme theme) =>
      DecoratedBox(decoration: _selection(theme, selected: true));

  // 分段条与预览一致：容器取抬高一档的表面，选中项取比它还亮一档的
  // [ZhixinColors.surfaceSelected] 并加一圈容器描边；未选中项保持透明。
  ShapeDecoration _selection(ZhixinTheme theme, {required bool selected}) =>
      ShapeDecoration(
        color: selected ? theme.colors.surfaceSelected : Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: theme.radius.control,
          side: BorderSide(
            color: selected ? theme.colors.outlineVariant : Colors.transparent,
          ),
        ),
      );

  Widget _segment(
    BuildContext context,
    ZhixinTheme theme,
    ZhixinSegment<T> segment,
    TextStyle labelStyle, {
    required bool expand,
  }) {
    final isSelected = segment.value == selected;
    final foreground = isSelected
        ? theme.colors.onPrimaryContainer
        : theme.colors.onSurfaceVariant;
    final child = forui.FTappable.static(
      selected: isSelected,
      semanticsInMutuallyExclusiveGroup: true,
      // 标签写短了的一项另给读屏一句完整说法，并把里面的短标签从语义里排除，
      // 读屏不会读成“AI 的改动 AI”。
      semanticsLabel: segment.semanticsLabel,
      excludeSemantics: segment.semanticsLabel != null,
      behavior: HitTestBehavior.opaque,
      focusedOutlineStyle: forui.FFocusedOutlineStyle(
        color: theme.colors.onSurface,
        borderRadius: theme.radius.card,
        width: 2,
        spacing: -2,
      ),
      onPress: () {
        if (!isSelected) onChanged(segment.value);
      },
      // 按下时这一项放大几个百分点：当前项再按一次没有动作，不放大。等分整行
      // 时放大的是这一项里面的内容，滑块与相邻项都不动。
      child: PressScale(
        enabled: !isSelected,
        child: AnimatedContainer(
          duration: context.motionOf(theme.motion.fast),
          curve: theme.motion.move,
          constraints: BoxConstraints(
            minWidth: _slotMinWidth,
            // 等分整行时与滚动排布都取 38：轨道高 44，减去 3 的上下内边距之后
            // 内容刚好填满，选中底色与文字上下居中，不留一条空白。
            minHeight: 38,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: theme.space.sm,
          ),
          // 等分整行时选中底色由滑块画，这里保持透明。
          decoration: _selection(theme, selected: isSelected && !expand),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (segment.icon != null) ...[
                Icon(segment.icon, size: _iconSize, color: foreground),
                const SizedBox(width: _iconSpacing),
              ],
              Flexible(
                // 选中与否都取同一个字重：选中态已经由滑块底色与文字颜色
                // 说明，字重再变会改变字宽，等分整行时标签会轻微重新居中。
                child: Text(
                  segment.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.text.labelLarge.copyWith(color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return expand ? Expanded(child: child) : child;
  }
}

/// 分段里的一项。
class ZhixinSegment<T> {
  const ZhixinSegment({
    required this.value,
    required this.label,
    this.icon,
    this.semanticsLabel,
  });

  final T value;

  /// 显示在整条里的短标签；空间不够时截断。
  final String label;
  final IconData? icon;

  /// 读屏用的完整说法；为空时读 [label]。标签为了等分排布可以写短，读屏仍
  /// 读出完整名称。
  final String? semanticsLabel;
}
