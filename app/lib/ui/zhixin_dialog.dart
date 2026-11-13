import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// 弹出一个 Forui 对话框。
///
/// 原来的页面直接 showDialog + AlertDialog，标题、正文与操作按钮由 Material
/// 排；改成 showFDialog + [ZhixinDialogLayout] 之后，遮罩、进出动画、圆角与
/// 按钮都跟页面共用 Forui 主题。返回值与 Navigator.pop 传的值一致。
Future<T?> showZhixinDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return forui.showFDialog<T>(
    context: context,
    builder: (context, style, animation) => forui.FDialog(
      animation: animation,
      builder: (context, style) => builder(context),
    ),
  );
}

/// 只需一句标题、一段正文与几个动作的对话框。
///
/// 页面里大部分确认框都按 [ZhixinDialogLayout] 排，调用方只写标题、正文与
/// 按钮即可，不必每次都展开一遍 builder 与布局。
Future<T?> showZhixinAlert<T>({
  required BuildContext context,
  required String title,
  required Widget content,
  required List<Widget> actions,
}) {
  return showZhixinDialog<T>(
    context: context,
    builder: (context) => ZhixinDialogLayout(
      title: Text(title),
      content: content,
      actions: actions,
    ),
  );
}

/// 对话框的标题、正文与操作按钮的排法。
///
/// 标题用 FDialog 的标题字号，正文可以滚动，操作按钮靠右换行排列。宽度交给
/// 外层 FDialog 的约束，手机上不会超出屏幕，平板上停在 560。
class ZhixinDialogLayout extends StatelessWidget {
  const ZhixinDialogLayout({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final style = context.theme.dialogStyle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DefaultTextStyle(style: style.titleTextStyle, child: title),
            const SizedBox(height: 12),
            Flexible(
              child: DefaultTextStyle(
                style: style.bodyTextStyle,
                child: SingleChildScrollView(child: content),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}
