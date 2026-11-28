import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../application/repository_integrity.dart';
import 'zhixin_dialog.dart';

/// 手动“检查数据完整性”的结果框：说明检查范围，再给通过或逐处不一致与建议。
Future<void> showIntegrityReport(
  BuildContext context,
  RepositoryIntegrityResult result,
) {
  final theme = context.zhixin;
  final body = StringBuffer();
  if (result.isClean) {
    body
      ..writeln('通过：重放得到的摘要与当前数据一致。')
      ..writeln(
        '共核对 ${result.checkedCommits} 条提交，HEAD 是提交 #${result.commitId}。',
      );
  } else {
    body.writeln('发现 ${result.problems.length} 处不一致：');
    for (var index = 0; index < result.problems.length; index++) {
      body.writeln('第 ${index + 1} 处：${result.problems[index]}');
    }
    body
      ..writeln()
      ..write(
        '建议：先不要导出或恢复；可以到提交历史里找到正确的版本恢复，'
        '内容还在其他设备上时也可以重新同步一次。',
      );
  }
  return showZhixinAlert<void>(
    context: context,
    title: '数据完整性检查',
    cancelLabel: '知道了',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(RepositoryIntegrityResult.scope, style: theme.text.bodySmall),
        SizedBox(height: theme.space.md),
        Text(body.toString().trimRight(), style: theme.text.bodyMedium),
      ],
    ),
    actions: const [],
  );
}

/// 导出前的自动检查：通过时直接返回真；发现不一致时先说明，再由用户决定是否
/// 继续导出。
///
/// [action] 是用户接下来要做的事，例如“备份版本库”“上传云端备份”，用于按钮与
/// 说明文字。返回真表示继续导出，假表示用户取消。
Future<bool> confirmExportAfterIntegrityCheck(
  BuildContext context,
  RepositoryIntegrityResult result, {
  required String action,
}) async {
  if (result.isClean) return true;
  final theme = context.zhixin;
  final lines = StringBuffer();
  for (var index = 0; index < result.problems.length; index++) {
    lines.writeln('第 ${index + 1} 处：${result.problems[index]}');
  }
  return showZhixinAlert<bool>(
    context: context,
    title: '$action前发现不一致',
    cancelLabel: '取消',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(RepositoryIntegrityResult.scope, style: theme.text.bodySmall),
        SizedBox(height: theme.space.md),
        Text(
          '发现 ${result.problems.length} 处不一致：',
          style: theme.text.labelLarge,
        ),
        SizedBox(height: theme.space.tight),
        Text(lines.toString().trimRight(), style: theme.text.bodySmall),
        SizedBox(height: theme.space.md),
        Text(
          '继续$action不会改动本机数据，但备份里可能缺内容；'
          '建议先处理这些不一致，或者确认只是本机改了数据之后再继续。',
          style: theme.text.bodySmall,
        ),
      ],
    ),
    actions: [
      forui.FButton(
        variant: forui.FButtonVariant.destructive,
        mainAxisSize: MainAxisSize.min,
        onPress: () => Navigator.of(context).pop(true),
        child: Text('仍然$action'),
      ),
    ],
  ).then((value) => value ?? false);
}
