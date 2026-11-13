import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// Forui 这一版没有芯片控件：可选项与操作项用 FButton 承担。
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
      prefix: icon == null ? null : Icon(icon),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
