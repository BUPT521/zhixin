import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 一组互斥的视图切换，例如记录里的“学习记录 / 材料”与安排里的四个页签。
///
/// 等宽时共用一个滑块，窄屏或放大文字时按内容宽度横向滚动。每一项按下去时
/// 放大几个百分点，松开或切换之后回位；当前项再按一次没有动作，不放大。
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
  static const _minTargetSize = 48.0;
  static const _iconSize = 16.0;
  static const _iconSpacing = 6.0;

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
        final fits =
            constraints.hasBoundedWidth &&
            slotWidth >= _minTargetSize &&
            _labelsFit(context, labelStyle, slotWidth - 2 * theme.space.md);
        final children = [
          for (final segment in segments)
            _segment(context, theme, segment, labelStyle, expand: fits),
        ];
        final index = segments.indexWhere((s) => s.value == selected);
        final row = Row(
          mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
          children: children,
        );
        final track = Container(
          padding: const EdgeInsets.all(_trackPadding),
          decoration: BoxDecoration(
            color: theme.colors.surfaceContainerHigh,
            borderRadius: theme.radius.card,
          ),
          child: fits && index >= 0
              ? Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedAlign(
                        duration: context.motionOf(theme.motion.standard),
                        curve: theme.motion.move,
                        alignment: AlignmentDirectional(
                          count == 1 ? 0 : -1 + 2 * index / (count - 1),
                          0,
                        ),
                        child: FractionallySizedBox(
                          widthFactor: 1 / count,
                          heightFactor: 1,
                          child: _thumb(theme),
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
              ? track
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

  ShapeDecoration _selection(ZhixinTheme theme, {required bool selected}) =>
      ShapeDecoration(
        color: selected ? theme.colors.primaryContainer : Colors.transparent,
        shape: const StadiumBorder(),
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
      // 按下时这一项放大几个百分点：当前项再按一次没有动作，不放大。
      child: PressScale(
        enabled: !isSelected,
        child: AnimatedContainer(
          duration: context.motionOf(theme.motion.fast),
          curve: theme.motion.move,
          constraints: const BoxConstraints(
            minWidth: _minTargetSize,
            minHeight: _minTargetSize,
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
                  style: labelStyle.copyWith(color: foreground),
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
