import '../data/revisions/revision_service.dart';

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
