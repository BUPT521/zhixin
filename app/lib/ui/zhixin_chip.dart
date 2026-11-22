import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 芯片式按钮的圆角：所有尺寸都取 [ZhixinRadius.tag]，比普通按钮的圆角小一档。
///
/// 芯片是排在行里的小标签，圆角跟着按钮走会显得过于圆；下拉框的触发器也用它，
/// 筛选条上的芯片与下拉框才是一套边框。
forui.FButtonStyleDelta chipButtonStyle(BuildContext context) =>
    forui.FButtonStyleDelta.delta(
      decoration:
          forui.FVariantsDelta<
            forui.FTappableVariantConstraint,
            forui.FTappableVariant,
            Decoration,
            forui.DecorationDelta
          >.delta([
            // 各种状态与尺寸的底色都保留，只改圆角。
            forui.FVariantOperation.all(
              forui.DecorationDelta.boxDelta(
                borderRadius: context.zhixin.radius.tag,
              ),
            ),
          ]),
    );

/// Forui 这一版没有芯片控件：可选项与操作项用 FButton 承担。
///
/// 圆角见 [chipButtonStyle]。
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
    return forui.FButton(
      variant: selected
          ? forui.FButtonVariant.secondary
          : forui.FButtonVariant.outline,
      size: size,
      mainAxisSize: MainAxisSize.min,
      selected: selected,
      onPress: onPressed,
      style: chipButtonStyle(context),
      prefix: icon == null ? null : Icon(icon),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
