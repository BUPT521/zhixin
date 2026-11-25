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
    this.control = const forui.FPopoverControl.managed(),
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

  /// 菜单显示与否的控制方式；默认自己管，点开与关掉都交给浮层控制器。
  final forui.FPopoverControl control;

  @override
  Widget build(BuildContext context) {
    return forui.FPopoverMenu.tiles(
      control: control,
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
///
/// 菜单要等到点开时才挂出来。一个 [ZhixinMenu] 带一套浮层控制器、焦点域与
/// 弹出层，记录列表一屏就有七八行，快速滑过时每帧都要新建几行；改成点开才
/// 挂之后，没点开的行只有一个普通图标按钮，滑过去不再付这份建树开销。
Widget moreMenu({
  required List<ZhixinMenuItem> items,
  String label = '更多',
  IconData icon = FLucideIcons.ellipsis,
}) => _LazyMoreMenu(items: items, label: label, icon: icon);

class _LazyMoreMenu extends StatefulWidget {
  const _LazyMoreMenu({
    required this.items,
    required this.label,
    required this.icon,
  });

  final List<ZhixinMenuItem> items;
  final String label;
  final IconData icon;

  @override
  State<_LazyMoreMenu> createState() => _LazyMoreMenuState();
}

class _LazyMoreMenuState extends State<_LazyMoreMenu> {
  /// 点开过一次就保持挂载；关掉之后再次点击由同一个浮层控制器打开，
  /// 这样反复开关不必重建菜单，也没有第二次建树。
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    if (!_opened) {
      return ZhixinIconButton(
        tooltip: widget.label,
        icon: widget.icon,
        onPressed: () => setState(() => _opened = true),
      );
    }
    return ZhixinMenu(
      semanticsLabel: widget.label,
      items: widget.items,
      // 点开发生在上一帧，这一次建树直接把菜单显示出来，用户只点一下。
      control: const forui.FPopoverControl.managed(initial: true),
      triggerBuilder: (context, controller) => ZhixinIconButton(
        tooltip: widget.label,
        icon: widget.icon,
        onPressed: controller.toggle,
      ),
    );
  }
}
