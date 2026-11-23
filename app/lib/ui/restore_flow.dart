import 'package:forui/forui.dart' as forui;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../app_scope.dart';
import '../data/backup/restore_inspection.dart';
import '../domain/models/result.dart';
import '../domain/rules/package_budget.dart';
import 'failure_feedback.dart';
import 'format.dart';
import 'zhixin_dialog.dart';

/// 恢复确认框：本机版本恢复与数据包恢复共用同一套来源、影响与回退说明。
///
/// 两个入口的包内容不同，确认之前都要先通过预检；框里的回退一律指向数据版本页，
/// 用户不必分辨这次恢复留下的是提交还是恢复点。本机版本恢复在目标提交还能折叠
/// 出净变化时只改有差异的行，数据包与恢复点恢复是整库替换；确认之后都会改动当前
/// 数据，按钮因此沿用危险样式。
Future<bool> showRestoreConfirmDialog(
  BuildContext context, {
  required String title,
  required List<String> sourceLines,
  required List<String> impactLines,
  required String rollbackLine,
}) async {
  final theme = context.zhixin;
  final confirmed = await confirmZhixin(
    context: context,
    title: title,
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in sourceLines)
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.tight),
            child: Text(line),
          ),
        SizedBox(height: theme.space.xs),
        for (final line in impactLines)
          Padding(
            padding: EdgeInsets.only(bottom: theme.space.xs),
            child: Text(line),
          ),
        SizedBox(height: theme.space.gap),
        Text(rollbackLine, style: theme.text.bodySmall),
      ],
    ),
    confirmLabel: '恢复',
    destructive: true,
  );
  return confirmed;
}

/// 数据包恢复的共用流程：选包、预检、说明影响与回退，再整库替换。
///
/// 恢复前的状态由 [DataVersionService.restore] 保存为恢复点，恢复成功后仍保留。
/// 包被拒时用户可以直接在主按钮上重新选择，不必退出这一页重来；预检期间与
/// 恢复期间的进度交给 [onStatus] 就地显示，只有最终结果由调用方提示。
/// 返回结果提示；用户取消或预检不通过时返回 null。
Future<String?> runPackageRestore(
  BuildContext context, {
  Uint8List? preset,
  String? origin,
  void Function(String message)? onStatus,
}) async {
  final scope = AppScope.of(context);
  final selected = await _selectAndInspect(
    context,
    preset: preset,
    onStatus: onStatus,
  );
  if (selected == null || !context.mounted) return null;
  final (bytes, inspection, fileName) = selected;

  final summary = await scope.data.versions.currentRestoreSummary();
  if (!context.mounted) return null;
  final confirmed = await showRestoreConfirmDialog(
    context,
    title: '从数据包恢复',
    sourceLines: [
      if (origin != null)
        '来源：$origin'
      else if (fileName != null)
        '文件：$fileName',
      ..._packageLines(inspection),
    ],
    impactLines: ['当前库会被整个替换，提交历史、命名版本与附件都以数据包为准。', _summaryLine(summary)],
    rollbackLine:
        '恢复前会自动把当前状态保存为一份恢复点；恢复完成后，'
        '可以在数据版本页的“恢复点”里回到恢复前。',
  );
  if (!confirmed || !context.mounted) {
    onStatus?.call('已取消恢复');
    return null;
  }

  onStatus?.call('正在恢复…');
  final Result<String?> restored;
  try {
    restored = await scope.data.versions.restore(bytes);
  } catch (error, stack) {
    if (!context.mounted) return '恢复失败，当前数据没有改动。';
    return describeFailure(
      context,
      error,
      stack,
      action: '恢复数据包',
      kind: 'restore_apply',
      kept: '当前数据保留',
      next: '可以检查数据包后重试',
    );
  }
  switch (restored) {
    case Success(:final value):
      return value == null
          ? '恢复完成；恢复前的状态已保存为恢复点，可在数据版本页回到恢复前'
          : '恢复完成；恢复前的状态已保存为恢复点。$value';
    case Failure(:final reason):
      if (!context.mounted) return reason.message;
      return describeFailureReason(
        context,
        reason,
        kind: 'restore_apply',
        kept: '当前数据保留',
        next: '可以检查数据包后重试',
      );
  }
}

/// 选包与预检；包被拒时在主按钮上给“重新选择”，用户取消时返回 null。
///
/// 恢复点这类已经定好来源的包不能重选，被拒之后只说明原因。
Future<(Uint8List, RestoreInspection, String?)?> _selectAndInspect(
  BuildContext context, {
  required Uint8List? preset,
  required void Function(String message)? onStatus,
}) async {
  final scope = AppScope.of(context);
  Uint8List? bytes = preset;
  String? fileName;
  while (true) {
    if (bytes == null) {
      final picked = await FilePicker.pickFile(dialogTitle: '选择数据包');
      if (picked == null) return null;
      fileName = picked.name;
      // 超过上限的包不读进内存：先看文件大小，再决定是否读取。
      final size = await picked.length();
      if (size != null && size > dataPackageMaxBytes) {
        final message = dataPackageTooLargeMessage(size);
        onStatus?.call(message);
        if (!context.mounted) return null;
        if (await _showRejectedPackage(
          context,
          message,
          allowReselect: preset == null,
        )) {
          fileName = null;
          continue;
        }
        return null;
      }
      onStatus?.call('正在读取数据包…');
      bytes = await picked.readAsBytes();
    }

    onStatus?.call('正在校验数据包…');
    final Result<RestoreInspection> inspected;
    try {
      inspected = await scope.data.versions.inspectRestorePackage(bytes);
    } catch (error, stack) {
      final message = context.mounted
          ? describeFailure(
              context,
              error,
              stack,
              action: '校验数据包',
              kind: 'restore_inspect',
              kept: '当前数据没有改动',
              next: '可以换一个数据包再试',
            )
          : '数据包不能恢复，当前数据没有改动。';
      onStatus?.call(message);
      if (!context.mounted) return null;
      if (await _showRejectedPackage(
        context,
        message,
        allowReselect: preset == null,
      )) {
        bytes = null;
        fileName = null;
        continue;
      }
      return null;
    }

    switch (inspected) {
      case Success(:final value):
        return (bytes, value, fileName);
      case Failure(:final reason):
        final message = context.mounted
            ? describeFailureReason(
                context,
                reason,
                kind: 'restore_inspect',
                kept: '当前数据没有改动',
                next: '可以换一个数据包再试',
              )
            : reason.message;
        onStatus?.call(message);
        if (!context.mounted) return null;
        if (await _showRejectedPackage(
          context,
          message,
          allowReselect: preset == null,
        )) {
          bytes = null;
          fileName = null;
          continue;
        }
        return null;
    }
  }
}

List<String> _packageLines(RestoreInspection inspection) {
  final exported = _exportedAt(inspection.exportedAt);
  final suffix = exported.isEmpty ? '' : '，导出于 $exported';
  return switch (inspection.kind) {
    RestorePackageKind.repository => [
      '版本库备份：HEAD ${inspection.head ?? 0}，'
          '${inspection.commitCount} 条提交，${inspection.namedCount} 个命名版本'
          '$suffix。',
    ],
    RestorePackageKind.currentData => [
      '当前数据包（schema v${inspection.schemaVersion}）'
          '${inspection.rowCount == 0 ? '' : '，共 ${inspection.rowCount} 条业务记录'}'
          '$suffix。',
    ],
  };
}

String _summaryLine(RestoreSummary summary) =>
    '当前库：HEAD ${summary.head}，${summary.commitCount} 条提交，'
    '${summary.namedCount} 个命名版本。';

String _exportedAt(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed == null ? '' : shortTime(parsed.toLocal());
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
