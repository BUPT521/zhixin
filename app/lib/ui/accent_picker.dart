import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 六个主题色的色块：设置页“外观”与首次启动引导的外观这一步共用。
///
/// 一行六个圆形色块，选中的带对勾与描边，点一下立即换色；主题色只换按钮、
/// 链接、选中态与强调卡片的颜色，页面与卡片底色不变。
class AccentPicker extends StatelessWidget {
  const AccentPicker({
    super.key,
    required this.selected,
    required this.onSelected,
    this.showLabel = true,
  });

  final ZhixinAccent selected;
  final ValueChanged<ZhixinAccent> onSelected;

  /// 是否显示“主题色”标题与一行说明；引导外观这一步的页面标题已经说明这件事，
  /// 不再重复。
  final bool showLabel;

  static const _swatchSize = 32.0;

  @override
  Widget build(BuildContext context) {
    final theme = context.zhixin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          Text(
            '主题色',
            style: theme.text.labelLarge.copyWith(
              color: theme.colors.onSurface,
            ),
          ),
          SizedBox(height: theme.space.xs),
          Text(
            '只换按钮、链接、选中态与强调卡片的颜色，页面与卡片保持纯白或纯黑。',
            style: theme.text.bodySmall.copyWith(
              color: theme.colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: theme.space.md),
        ],
        Row(
          children: [
            for (final accent in ZhixinAccent.values)
              Expanded(
                child: _AccentSwatch(
                  accent: accent,
                  selected: accent == selected,
                  onPressed: () => onSelected(accent),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.accent,
    required this.selected,
    required this.onPressed,
  });

  final ZhixinAccent accent;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.zhixin.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: '${accent.label}主题色',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Container(
              width: AccentPicker._swatchSize,
              height: AccentPicker._swatchSize,
              decoration: BoxDecoration(
                color: accent.light,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? colors.onSurface : colors.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              // 对勾压在主色上：主色偏暗时用白，偏亮（深色的石墨）时用正文色。
              child: selected
                  ? Icon(
                      Icons.check,
                      size: 18,
                      color: accent.light.computeLuminance() > 0.4
                          ? colors.onSurface
                          : const Color(0xFFFFFFFF),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
