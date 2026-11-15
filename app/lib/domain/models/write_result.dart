/// 一次写操作的结果：有没有形成提交、提交编号，以及没有变化时的原因。
///
/// 服务层原先用 `int?`、`void`、领域对象与异常混着表达写入结果；统一成这个
/// 对象之后，界面只判断 [changed] 与 [commitId]，异常只表示程序错误。
class WriteResult {
  const WriteResult.committed(int id)
    : commitId = id,
      changed = true,
      skippedReason = null;

  const WriteResult.skipped([this.skippedReason])
    : commitId = null,
      changed = false;

  /// 这次写入形成的提交编号；没有形成提交时为空。
  final int? commitId;

  /// 是否形成了提交。
  final bool changed;

  /// 没有形成提交时的原因，供界面提示；没有变化与主动跳过共用这一栏。
  final String? skippedReason;

  /// 由可能为空的提交编号得到结果；为空时按跳过处理。
  static WriteResult of(int? commitId, {String? skippedReason}) =>
      commitId == null
      ? WriteResult.skipped(skippedReason)
      : WriteResult.committed(commitId);
}
