import '../revisions/revision_models.dart';
import 'guarded_database.dart';
import 'raw_executor.dart';

/// 一次业务写入拿到的执行器；同一命令里的仓库共用它。
class WriteTransaction {
  WriteTransaction(this.executor);

  /// 同一事务的执行器；仓库把它传给需要 SQL 执行器的查询。
  final RawExecutor executor;

  /// 本次命令已分配的提交编号；界面回执用它指回提交历史。
  Future<int?> commitId() async {
    final rows = await executor.query(
      'revision_context',
      columns: ['active_commit'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['active_commit'] as int?;
  }

  /// 写入必须落在一次提交里，没有提交编号时不能留可撤销的回执。
  Future<int> requireCommitId() async {
    final id = await commitId();
    if (id == null) throw StateError('这次写入没有进入数据版本，无法生成回执');
    return id;
  }
}

class WriteTransactions {
  const WriteTransactions(this._db);

  final RawDatabase _db;

  /// 一次业务动作；[label] 写进数据变更历史，[requestId] 用于重试去重。
  Future<T> run<T>(
    Future<T> Function(WriteTransaction) action, {
    String label = '数据写入',
    String actor = 'user',
    String? requestId,
    T Function(RevisionCommit commit)? onDuplicate,
  }) {
    final db = _db;
    if (db is GuardedDatabase) {
      return db.command(
        (txn) => action(WriteTransaction(txn)),
        label: label,
        actor: actor,
        requestId: requestId,
        onDuplicate: onDuplicate,
      );
    }
    return db.transaction((txn) => action(WriteTransaction(txn)));
  }
}

RawExecutor writeExecutor(WriteTransaction? transaction, RawExecutor db) =>
    transaction?.executor ?? db;
