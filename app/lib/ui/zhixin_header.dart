import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 标题栏左右边距从 [ZhixinSpace.page] 里收掉的宽度，等于图标按钮可点区域
/// 与 20 的图标之间那一半留白；见 [ZhixinHeader] 的说明。
const double _iconInset = 6;

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
    final theme = context.zhixin;
    // 标题栏里图标按钮的可点区域是 44 见方，图标居中；左右边距各收 6，图标
    // 与标题文字离屏边是 [ZhixinSpace.page]，与下面内容的行首对齐。
    final style = forui.FHeaderStyleDelta.delta(
      padding: .value(
        EdgeInsets.symmetric(
          horizontal: theme.space.page - _iconInset,
          vertical: 6,
        ),
      ),
      // 标签页的根标题与二级页同一档 titleLarge，只是根页面靠左。
      titleTextStyle: .value(theme.text.titleLarge),
      constraints: BoxConstraints(minHeight: nested ? 56 : 52),
      actionSpacing: theme.space.xs,
      actionStyle: .delta(
        padding: const .value(EdgeInsets.all(12)),
        iconStyle: .delta([.all(.delta(size: 20))]),
      ),
    );
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
            style: style,
            title: title,
            prefixes: leading,
            suffixes: actions,
          )
        : forui.FHeader(style: style, title: title, suffixes: actions);
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
