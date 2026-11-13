import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 一组互斥的视图切换，例如记录里的“学习记录 / 材料”与安排里的四个页签。
///
/// 原来用一排芯片表示页签，与下方的筛选芯片样式相同，用户分不清哪一排是
/// 切换视图、哪一排是筛选。分段控件的选中项使用主色浅底；
/// 段数少时等分整行，段数多或文字长时按内容宽度横向滚动。
///
/// 等分整行时，选中的卡片色滑块从原来的段滑到新的段，说明视图换到了哪里；
/// 横向滚动时各段宽度不同，选中色在原地渐变。
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
            borderRadius: theme.radius.control,
          ),
          child: fits && index >= 0
              ? Stack(
                  children: [
                    Positioned.fill(
                      child: AnimatedAlign(
                        duration: context.motionOf(theme.motion.standard),
                        curve: theme.motion.move,
                        alignment: Alignment(
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

  Widget _thumb(ZhixinTheme theme) => DecoratedBox(
    decoration: BoxDecoration(
      color: theme.colors.primaryContainer,
      borderRadius: theme.radius.tag,
    ),
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
          decoration: BoxDecoration(
            color: isSelected && !expand
                ? theme.colors.primaryContainer
                : Colors.transparent,
            borderRadius: theme.radius.tag,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (segment.icon != null) ...[
                Icon(segment.icon, size: 16, color: foreground),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  segment.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.text.labelLarge.copyWith(
                    color: foreground,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
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
