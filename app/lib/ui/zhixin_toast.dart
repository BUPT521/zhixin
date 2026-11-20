import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

/// 页面底部的短提示统一走 Forui 的 FToast。
///
/// 原来各页直接调 ScaffoldMessenger.showSnackBar，提示随 Material 的 SnackBar
/// 样式走；改成 FToast 之后，提示的底色、圆角与关闭方式与页面共用同一套
/// Forui 主题。FToast 需要上层有 FToaster，应用根已经装好；测试里单独构建
/// 页面时要自己补一个 FToaster。
void showToast(BuildContext context, String message) {
  forui.showFToast(
    context: context,
    title: Text(message),
    duration: toastDuration(context),
  );
}

/// 短提示自动收起的时长：手机上 3 秒，桌面上 5 秒。
///
/// 提示落在下方之后挡住的内容少，手机上读完一句用不了几秒，收起得早一些；
/// 桌面上鼠标可以移到提示上展开再看，保留 Forui 默认的 5 秒。带按钮的提示
/// 不按这个时长，见 [showActionToast]。
Duration toastDuration(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => const Duration(seconds: 3),
      _ => const Duration(seconds: 5),
    };

/// 带一个操作按钮的提示，用在可以撤销的提交与需要补一步配置的失败上。
///
/// 按钮放在提示的尾部；点过之后先收起提示，再执行原来的动作。带按钮的提示
/// 要留出看清提示再点按钮的时间，手机上同样按 Forui 默认的 5 秒收起。
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
