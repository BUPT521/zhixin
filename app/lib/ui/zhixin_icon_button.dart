import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// 只带图标的按钮；[tooltip] 同时作为读屏标签。
///
/// FButton.icon 本身不带可见提示，这里不再包一层 FTooltip：手机上没有悬停，
/// 桌面端的提示随按钮一起去掉，读屏仍然读同一句。
class ZhixinIconButton extends StatelessWidget {
  const ZhixinIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.variant = forui.FButtonVariant.ghost,
    this.size = forui.FButtonSizeVariant.md,
    this.iconColor,
    this.style = const forui.FButtonStyleDelta.context(),
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final forui.FButtonVariant variant;
  final forui.FButtonSizeVariant size;
  final Color? iconColor;
  final forui.FButtonStyleDelta style;

  @override
  Widget build(BuildContext context) {
    return forui.FButton.icon(
      variant: variant,
      size: size,
      style: style,
      onPress: onPressed,
      semanticsLabel: tooltip,
      semanticsTooltip: tooltip,
      child: Icon(icon, color: iconColor),
    );
  }
}
