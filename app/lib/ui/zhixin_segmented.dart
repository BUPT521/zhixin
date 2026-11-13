import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 一组互斥的视图切换，例如记录里的“学习记录 / 材料”与安排里的四个页签。
///
/// 等宽时共用一个滑块，窄屏或放大文字时按内容宽度横向滚动。
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

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final fits = constraints.maxWidth / segments.length >= 76 * textScale;
        final children = [
          for (final segment in segments)
            _segment(context, theme, segment, expand: fits),
        ];
        final index = segments.indexWhere((s) => s.value == selected);
        final count = segments.length;
        final row = Row(
          mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
          children: children,
        );
        final track = Container(
          padding: const EdgeInsets.all(3),
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
    ZhixinSegment<T> segment, {
    required bool expand,
  }) {
    final isSelected = segment.value == selected;
    final foreground = isSelected
        ? theme.colors.onPrimaryContainer
        : theme.colors.onSurfaceVariant;
    final child = Semantics(
      button: true,
      selected: isSelected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isSelected ? null : () => onChanged(segment.value),
        child: AnimatedContainer(
          duration: context.motionOf(theme.motion.fast),
          curve: theme.motion.move,
          constraints: const BoxConstraints(minHeight: 42),
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
                Icon(segment.icon, size: 16, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                // 选中与否都取同一个字重：选中态已经由滑块底色与文字颜色
                // 说明，字重再变会改变字宽，等分整行时标签会轻微重新居中。
                child: Text(
                  segment.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.text.labelLarge.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
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
