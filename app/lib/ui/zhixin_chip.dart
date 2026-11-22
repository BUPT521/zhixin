import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Forui 这一版没有芯片控件：可选项与操作项用 FButton 承担。
///
/// 所有尺寸的芯片圆角统一取 [ZhixinRadius.tag]，比按钮的圆角小一档：芯片是
/// 排在行里的一个小标签，圆角跟着按钮走会显得过于圆。
class ZhixinChip extends StatelessWidget {
  /// 可点选的选项或操作，[selected] 为真时用次色底。
  const ZhixinChip({
    required this.label,
    this.selected = false,
    this.onPressed,
    this.icon,
    this.size = forui.FButtonSizeVariant.xs,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final IconData? icon;
  final forui.FButtonSizeVariant size;

  @override
  Widget build(BuildContext context) {
    final radius = context.zhixin.radius.tag;
    return forui.FButton(
      variant: selected
          ? forui.FButtonVariant.secondary
          : forui.FButtonVariant.outline,
      size: size,
      mainAxisSize: MainAxisSize.min,
      selected: selected,
      onPress: onPressed,
      style: forui.FButtonStyleDelta.delta(
        decoration:
            forui.FVariantsDelta<
              forui.FTappableVariantConstraint,
              forui.FTappableVariant,
              Decoration,
              forui.DecorationDelta
            >.delta([
              // 各种状态与尺寸的底色都保留，只改圆角。
              forui.FVariantOperation.all(
                forui.DecorationDelta.boxDelta(borderRadius: radius),
              ),
            ]),
      ),
      prefix: icon == null ? null : Icon(icon),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
