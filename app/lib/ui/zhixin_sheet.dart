import 'package:material_ui/material_ui.dart';

/// 从底部滑出的面板，底色、上圆角与拖动条由 Material 的底部面板主题提供。
///
/// 高度交给 `isScrollControlled`：内容少时按内容高度停住，内容多时在面板里
/// 滚动，不会被截到 9/16。顶部安全区由 `useSafeArea` 处理，底部安全区收在
/// [ZhixinSheet] 里，调用方不再各自包一层。
Future<T?> showZhixinSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => ZhixinSheet(child: builder(context)),
  );
}

/// 面板内容外面的底部安全区；顶部的安全区由 [showZhixinSheet] 处理。
class ZhixinSheet extends StatelessWidget {
  const ZhixinSheet({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(top: false, child: child);
}
