import 'package:forui/forui.dart' as forui;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

import '../data/revisions/revision_service.dart';
import 'zhixin_dialog.dart';

/// 一次数据完整性检查的结果：重放比对一项，附件核对一项。
///
/// 数据层把这两项分开提供：`verifyIntegrity` 从最近的检查点把变更明细重放到
/// `HEAD`，把重放得到的摘要与 `HEAD` 记录、按当前表重算的摘要各比一次，并指出
/// 不一致的表；`verifyAssets` 核对检查点、变更明细与当前投影引用的附件。界面
/// 把两项合成一次检查，导出前与手动入口用同一份结果（方案 3.10）。
class RepositoryIntegrityResult {
  const RepositoryIntegrityResult({
    required this.commitId,
    required this.checkedCommits,
    required this.problems,
  });

  /// 检查时的 `HEAD`。
  final int commitId;

  /// 重放的提交条数。
  final int checkedCommits;

  /// 发现的问题，中文说明；为空表示数据一致。
  final List<String> problems;

  bool get isClean => problems.isEmpty;

  /// 检查范围的说明：手动入口与导出前提示都用这一句。
  static const String scope =
      '检查范围：从最近的检查点把变更明细重放到 HEAD，重放摘要与 HEAD 记录、'
      '按当前表重算的摘要比对，再核对附件。';
}

/// 检查一次：重放比对，再加附件核对；两项都有问题时一起列出来。
Future<RepositoryIntegrityResult> checkRepositoryIntegrity(
  RevisionService revisions,
) async {
  final report = await revisions.verifyIntegrity();
  final missingAssets = await revisions.verifyAssets();
  return RepositoryIntegrityResult(
    commitId: report.commitId,
    checkedCommits: report.checkedCommits,
    problems: [
      ...report.problems,
      if (missingAssets.isNotEmpty)
        '有 ${missingAssets.length} 个附件读不出或校验不符'
            '（${missingAssets.take(3).join('、')}'
            '${missingAssets.length > 3 ? ' 等' : ''}）',
    ],
  );
}

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
