import 'package:forui/forui.dart' as forui;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../application/data_version_flows.dart';
import 'failure_feedback.dart';
import 'zhixin_dialog.dart';

/// 恢复确认框：本机版本恢复与数据包恢复共用同一套来源、影响与回退说明。
///
/// 两个入口的包内容不同，确认之前都要先通过预检；框里的回退一律指向数据版本页，
/// 用户不必分辨这次恢复留下的是提交还是恢复点。本机版本恢复在目标提交还能折叠
/// 出净变化时只改有差异的行，数据包与恢复点恢复是整库替换；确认之后都会改动当前
/// 数据，按钮因此沿用危险样式。
Future<bool> showRestoreConfirmDialog(
  BuildContext context, {
  required RestorePrompt prompt,
}) async {
  final theme = context.zhixin;
  final confirmed = await confirmZhixin(
    context: context,
    title: prompt.title,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in prompt.sourceLines)
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.tight),
            child: Text(line),
          ),
        SizedBox(height: theme.space.xs),
        for (final line in prompt.impactLines)
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.xs),
            child: Text(line),
          ),
        SizedBox(height: theme.space.gap),
        Text(prompt.rollbackLine, style: theme.text.bodySmall),
      ],
    ),
    confirmLabel: '恢复',
    destructive: true,
  );
  return confirmed;
}

/// 数据包恢复的界面入口：选包、确认、拒绝后的重选与进度交给页面。
///
/// 选包之后的预检、当前库摘要、确认说明、整库替换与结果文案都由
/// [DataVersionFlows.restorePackage] 给出；这里只把文件选择器、两个弹框与
/// 本机诊断记录接上。恢复前的状态由数据层保存为恢复点，恢复成功后仍保留。
/// 包被拒时用户可以直接在主按钮上重新选择，不必退出这一页重来；预检期间与
/// 恢复期间的进度交给 [onStatus] 就地显示，只有最终结果由调用方提示。
/// 返回结果提示；用户取消或预检不通过时返回 null。
Future<String?> runPackageRestore(
  BuildContext context, {
  Uint8List? preset,
  String? origin,
  void Function(String message)? onStatus,
}) {
  final flows = AppScope.of(context).dataVersionFlows();
  return flows.restorePackage(
    preset: preset,
    origin: origin,
    host: RestoreHost(
      isActive: () => context.mounted,
      pickFile: () async {
        if (!context.mounted) return null;
        final picked = await FilePicker.pickFile(dialogTitle: '选择数据包');
        if (picked == null) return null;
        return RestorePackageFile(
          name: picked.name,
          size: await picked.length(),
          read: picked.readAsBytes,
        );
      },
      confirm: (prompt) async {
        if (!context.mounted) return false;
        return showRestoreConfirmDialog(context, prompt: prompt);
      },
      reject: (message, {required allowReselect}) async {
        if (!context.mounted) return false;
        return _showRejectedPackage(
          context,
          message,
          allowReselect: allowReselect,
        );
      },
      // 校验、恢复与预检的失败说明仍由页面写进本机诊断记录；页面已经离开时
      // 不再读应用作用域，直接用流程给的兜底说明。
      describeUnexpected:
          (
            error,
            stack, {
            required action,
            required kind,
            required kept,
            required next,
            required fallback,
          }) => context.mounted
          ? describeFailure(
              context,
              error,
              stack,
              action: action,
              kind: kind,
              kept: kept,
              next: next,
            )
          : fallback,
      describeReason: (reason, {required kind, required kept, required next}) =>
          context.mounted
          ? describeFailureReason(
              context,
              reason,
              kind: kind,
              kept: kept,
              next: next,
            )
          : reason.message,
      onStatus: onStatus,
    ),
  );
}

/// 包不能恢复时就地说明原因；还能重新选包时主按钮直接回到选择。
Future<bool> _showRejectedPackage(
  BuildContext context,
  String message, {
  required bool allowReselect,
}) async {
  if (!allowReselect) {
    await showZhixinAlert<void>(
      context: context,
      title: '数据包不能恢复',
      content: Text(message),
      actions: [
        forui.FButton(
          variant: forui.FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
    return false;
  }
  final reselect = await showZhixinAlert<bool>(
    context: context,
    title: '数据包不能恢复',
    content: Text(message),
    cancelLabel: '取消',
    actions: [
      forui.FButton(
        mainAxisSize: MainAxisSize.min,
        onPress: () => Navigator.of(context).pop(true),
        child: const Text('重新选择'),
      ),
    ],
  );
  return reselect ?? false;
}
