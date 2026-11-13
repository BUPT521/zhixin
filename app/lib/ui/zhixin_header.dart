import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// 页面顶部的一条标题栏。
///
/// 原来的页面用 AppBar，进入下一页时由它自动带返回箭头；换成 FHeader 之后
/// 返回按钮要自己放。标签页里当根页面的用 [nested] 为 false，标题靠左；从别处
/// 推进来的页面用默认的 nested，标题居中，需要返回时打开 [showBack]。标题栏
/// 左侧除了返回还可以放 [prefixes]，右侧放 [actions]。
class ZhixinHeader extends StatelessWidget {
  const ZhixinHeader({
    required this.title,
    this.actions = const [],
    this.prefixes = const [],
    this.showBack = false,
    this.nested = true,
    super.key,
  });

  final Widget title;
  final List<Widget> actions;
  final List<Widget> prefixes;
  final bool showBack;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final leading = <Widget>[
      if (showBack)
        forui.FHeaderAction.back(
          key: const ValueKey('zhixin-header-back'),
          onPress: () => Navigator.maybePop(context),
          semanticsLabel: '返回',
        ),
      ...prefixes,
    ];
    return nested
        ? forui.FHeader.nested(
            title: title,
            prefixes: leading,
            suffixes: actions,
          )
        : forui.FHeader(title: title, suffixes: actions);
  }
}

/// 标题栏右侧的图标动作，读屏标签用同一句。
class ZhixinHeaderAction extends StatelessWidget {
  const ZhixinHeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return forui.FHeaderAction(
      icon: Icon(icon),
      onPress: onPressed,
      semanticsLabel: tooltip,
      semanticsTooltip: tooltip,
    );
  }
}

/// 标题栏右侧的文字动作，按钮压到标题栏能用的尺寸。
class ZhixinHeaderButton extends StatelessWidget {
  const ZhixinHeaderButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return forui.FButton(
      variant: forui.FButtonVariant.ghost,
      size: forui.FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.min,
      onPress: onPressed,
      child: Text(label),
    );
  }
}
