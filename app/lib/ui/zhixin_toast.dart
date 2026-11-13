import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// 页面底部的短提示统一走 Forui 的 FToast。
///
/// 原来各页直接调 ScaffoldMessenger.showSnackBar，提示随 Material 的 SnackBar
/// 样式走；改成 FToast 之后，提示的底色、圆角与关闭方式与页面共用同一套
/// Forui 主题。FToast 需要上层有 FToaster，应用根已经装好；测试里单独构建
/// 页面时要自己补一个 FToaster。
void showToast(BuildContext context, String message) {
  forui.showFToast(context: context, title: Text(message));
}

/// 带一个操作按钮的提示，用在可以撤销的提交与需要补一步配置的失败上。
///
/// 按钮放在提示的尾部；点过之后先收起提示，再执行原来的动作。
void showActionToast(
  BuildContext context,
  String message, {
  required String label,
  required VoidCallback onPressed,
}) {
  forui.showFToast(
    context: context,
    title: Text(message),
    suffixBuilder: (context, entry) => forui.FButton(
      variant: forui.FButtonVariant.ghost,
      size: forui.FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.min,
      onPress: () {
        entry.dismiss();
        onPressed();
      },
      child: Text(label),
    ),
  );
}
