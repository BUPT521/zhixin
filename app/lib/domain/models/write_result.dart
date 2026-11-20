/// 一次写操作的结果：有没有形成提交、提交编号，以及没有变化时的原因。
///
/// 服务层原先用 `int?`、`void`、领域对象与异常混着表达写入结果；统一成这个
/// 对象之后，界面只判断 [changed] 与 [commitId]，异常只表示程序错误。
///
/// [changed] 与“是否真的落库”一致：命令结束之后没有形成提交时，即使命令里
/// 提前预留了编号，也不会返回“已提交”（R1）。
class WriteResult {
  const WriteResult.committed(int id)
    : commitId = id,
      changed = true,
      skippedReason = null,
      pending = false;

  const WriteResult.skipped([this.skippedReason])
    : commitId = null,
      changed = false,
      pending = false;

  /// 命令还没结束时的占位结果：收尾之后才知道有没有形成提交。
  ///
  /// 只有 `WriteTransaction.result` 会产生；`WriteTransactions.run` 在命令
  /// 结束后把它换成 [WriteResult.committed] 或 [WriteResult.skipped]，所以
  /// 服务层与界面拿到的结果不会是这一个。
  const WriteResult.pending([this.skippedReason])
    : commitId = null,
      changed = false,
      pending = true;

  /// 这次写入形成的提交编号；没有形成提交时为空。
  final int? commitId;

  /// 是否形成了提交。
  final bool changed;

  /// 没有形成提交时的原因，供界面提示；没有变化与主动跳过共用这一栏。
  final String? skippedReason;

  /// 是否是等待命令收尾的占位结果。
  final bool pending;

  /// 由可能为空的提交编号得到结果；为空时按跳过处理。
  static WriteResult of(int? commitId, {String? skippedReason}) =>
      commitId == null
      ? WriteResult.skipped(skippedReason)
      : WriteResult.committed(commitId);
}
