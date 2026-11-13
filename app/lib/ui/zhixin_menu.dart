import 'package:forui/forui.dart' as forui;
import 'package:forui_lucide/forui_lucide.dart' show FLucideIcons;
import 'package:material_ui/material_ui.dart';

import 'zhixin_icon_button.dart';

/// 一项菜单：文字、选中状态与禁用时仍要显示的说明。
class ZhixinMenuItem {
  const ZhixinMenuItem({
    required this.label,
    this.onSelected,
    this.enabled = true,
    this.selected = false,
    this.subtitle,
  });

  final String label;
  final VoidCallback? onSelected;
  final bool enabled;
  final bool selected;
  final String? subtitle;
}

/// 用 FPopoverMenu 承担原 PopupMenuButton 的菜单：触发器由调用方给，菜单项按顺序排。
class ZhixinMenu extends StatelessWidget {
  const ZhixinMenu({
    required this.semanticsLabel,
    required this.items,
    required this.triggerBuilder,
    this.menuAnchor = AlignmentDirectional.topEnd,
    this.childAnchor = AlignmentDirectional.bottomEnd,
    super.key,
  });

  final String semanticsLabel;
  final List<ZhixinMenuItem> items;
  final Widget Function(
    BuildContext context,
    forui.FPopoverController controller,
  )
  triggerBuilder;
  final AlignmentGeometry menuAnchor;
  final AlignmentGeometry childAnchor;

  @override
  Widget build(BuildContext context) {
    return forui.FPopoverMenu.tiles(
      semanticsLabel: semanticsLabel,
      barrierSemanticsLabel: '关闭$semanticsLabel',
      menuAnchor: menuAnchor,
      childAnchor: childAnchor,
      builder: (context, controller, _) => triggerBuilder(context, controller),
      menuBuilder: (context, controller, _) => [
        forui.FTileGroup(
          children: [
            for (final item in items)
              forui.FTile(
                title: Text(item.label),
                subtitle: item.subtitle == null ? null : Text(item.subtitle!),
                enabled: item.enabled,
                selected: item.selected,
                suffix: item.selected ? const Icon(FLucideIcons.check) : null,
                onPress: item.enabled
                    ? () {
                        controller.hide();
                        item.onSelected?.call();
                      }
                    : null,
              ),
          ],
        ),
      ],
    );
  }
}

/// 三横点触发的菜单，多数列表项的“更多”入口用这一种。
ZhixinMenu moreMenu({
  required List<ZhixinMenuItem> items,
  String label = '更多',
  IconData icon = FLucideIcons.ellipsis,
}) => ZhixinMenu(
  semanticsLabel: label,
  items: items,
  triggerBuilder: (context, controller) => ZhixinIconButton(
    tooltip: label,
    icon: icon,
    onPressed: controller.toggle,
  ),
);
