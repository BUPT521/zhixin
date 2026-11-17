import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// 从底部滑出的面板，底色、上圆角与拖动条由 Material 的底部面板主题提供。
///
/// 高度交给 `isScrollControlled`：内容少时按内容高度停住，内容多时在面板里
/// 滚动，不会被截到 9/16。顶部安全区由 `useSafeArea` 处理，底部安全区收在
/// [ZhixinSheet] 里，调用方不再各自包一层。
///
/// 面板有自己的标题时传 [title]：标题用 titleMedium，内容与标题的左右边距
/// 都取 `space.page`，各面板不再各写一套 16 或 20。不传 [title] 时保持原来的
/// 外观，还没改到的调用方不受影响。
Future<T?> showZhixinSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => ZhixinSheet(title: title, child: builder(context)),
  );
}

/// 面板内容外面的底部安全区与可选标题；顶部的安全区由 [showZhixinSheet] 处理。
class ZhixinSheet extends StatelessWidget {
  const ZhixinSheet({required this.child, this.title, super.key});

  final Widget child;

  /// 面板标题；为空时不显示标题，也不额外加边距。
  final String? title;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    if (title == null) return SafeArea(top: false, child: child);
    final theme = context.zhixin;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          theme.space.page,
          0,
          theme.space.page,
          theme.space.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: theme.space.md),
              child: Semantics(
                header: true,
                child: Text(title, style: theme.text.titleMedium),
              ),
            ),
            // 内容多时由它自己滚动：面板给的高度有上限，Flexible 让滚动区
            // 停在剩余高度里，不会把标题顶出屏幕。
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}
