import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 一组互斥的视图切换，例如记录里的“学习记录 / 材料”与安排里的四个页签。
///
/// 等宽时共用一个滑块，窄屏或放大文字时按内容宽度横向滚动。整条与按钮、
/// 输入框同高 [ZhixinSpace.controlHeight]；每一项按下去时放大几个百分点，松开
/// 或切换之后回位，当前项再按一次没有动作，不放大，滑块也不跟着放大。
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

  /// 等分一项时扣掉的横向内边距：左右各 [ZhixinSpace.md]。
  static const _slotInsets = 24.0;

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
                    // 滑块按整条等宽排好，只做一层透明度过渡：两端的定位与宽度
                    // 固定不动，切换只换画哪一块。
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, track) => AnimatedSwitcher(
                          duration: context.motionOf(theme.motion.standard),
                          child: KeyedSubtree(
                            key: ValueKey(index),
                            child: Align(
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

  // 分段条与预览一致：容器取抬高一档的表面，选中项取卡片底色并加一圈容器
  // 描边，选中字用正文色，未选中用次要文字色。
  ShapeDecoration _selection(ZhixinTheme theme, {required bool selected}) =>
      ShapeDecoration(
        color: selected ? theme.colors.card : Colors.transparent,
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
            // 等分整行时由整条撑满控件高度，这一项跟着撑满；滚动排布时取一档，
            // 文字放大之后仍放得下。
            minHeight: expand ? 0 : 38,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: theme.space.md,
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
  const ZhixinSegment({required this.value, required this.label, this.icon});
  final T value;
  final String label;
  final IconData? icon;
}
