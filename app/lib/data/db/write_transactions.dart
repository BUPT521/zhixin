import '../revisions/revision_engine.dart';
import '../revisions/revision_models.dart';
import '../../domain/models/write_result.dart';
import 'guarded_database.dart';
import 'raw_executor.dart';

/// 一次业务写入拿到的执行器；同一命令里的仓库共用它。
class WriteTransaction {
  WriteTransaction(this.executor, {required this.revisions});

  /// 同一事务的执行器；仓库把它传给需要 SQL 执行器的查询。
  final RawExecutor executor;

  /// 这次写入所属的数据版本引擎；预留编号与读回执都经它完成。
  final RevisionEngine revisions;

  /// 本次命令已经预留的提交编号；还没有预留时为空。
  Future<int?> commitId() => revisions.activeCommit(executor);

  /// 为本次命令预留提交编号并写进上下文；已经预留过时返回原编号。
  ///
  /// 只有必须把编号存进同一事务里的行（回执、卡片状态）时才调用；只在命令
  /// 结束之后才需要结果的路径用 [result]，不提前占号（R1）。
  Future<int> requireCommitId() => revisions.reserveCommitId(executor);

  /// 本次写入的结果：命令收尾后由 [WriteTransactions.run] 按是否形成提交换成
  /// 提交结果或跳过。
  ///
  /// 这里不预留编号：没有净变化时序号不动。
  Future<WriteResult> result({String? skippedReason}) async =>
      WriteResult.pending(skippedReason);
}

class WriteTransactions {
  WriteTransactions(this._db, {required this.revisions});

  final RawDatabase _db;

  /// 数据版本引擎；命令的开始、收尾与编号分配都经它完成。
  final RevisionEngine revisions;

  /// 一次业务动作；[label] 写进数据变更历史，[uid] 是这次动作的提交身份，
  /// [kind] 是提交类型（维护、写入等，见 `RevisionKind`）。
  ///
  /// 结果里的 [WriteResult] 在命令结束之后才定稿：没有形成提交时改成
  /// [WriteResult.skipped]，形成提交时补上落库的提交编号（R1）。把结果包在
  /// 记录里返回的调用方要在 [run] 之外组装，否则拿到的还是占位结果。
  Future<T> run<T>(
    Future<T> Function(WriteTransaction) action, {
    String label = '数据写入',
    String actor = 'user',
    String? uid,
    RevisionKind kind = RevisionKind.write,
    T Function(RevisionCommit commit)? onDuplicate,
  }) async {
    final db = _db;
    if (db is GuardedDatabase) {
      final outcome = await db.commandOutcome(
        (executor) => action(WriteTransaction(executor, revisions: revisions)),
        label: label,
        actor: actor,
        uid: uid,
        kind: kind,
        onDuplicate: onDuplicate,
      );
      return _settle(outcome.value, outcome.commit);
    }
    // 没有命令入口的库（测试里的原始执行器）不会形成提交，占位结果按跳过处理。
    final value = await db.transaction(
      (executor) => action(WriteTransaction(executor, revisions: revisions)),
    );
    return _settle(value, null);
  }

  /// 按这次命令是否形成提交换掉结果里的占位值。
  ///
  /// 请求重试时 [commit] 是原提交：保留调用方返回的已提交或跳过，不改成别的。
  static T _settle<T>(T value, RevisionCommit? commit) {
    if (value is! WriteResult) return value;
    final WriteResult result = value;
    if (commit == null) {
      return (result.changed || result.pending
              ? WriteResult.skipped(result.skippedReason)
              : result)
          as T;
    }
    return (result.pending ? WriteResult.committed(commit.id) : result) as T;
  }
}

RawExecutor writeExecutor(WriteTransaction? transaction, RawExecutor db) =>
    transaction?.executor ?? db;
