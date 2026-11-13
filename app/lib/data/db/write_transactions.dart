import 'package:sqflite/sqflite.dart';

import '../revisions/revision_models.dart';
import 'guarded_database.dart';

/// 供多个仓库共享一次写入事务。只有数据层需要取出底层执行器。
extension type WriteTransaction._(Transaction _transaction) {
  /// 同一事务的执行器；仓库把它传给需要 `DatabaseExecutor` 的查询。
  DatabaseExecutor get executor => _transaction;

  /// 本次命令已分配的提交编号；界面回执用它指回提交历史。
  Future<int?> commitId() async {
    final rows = await _transaction.query(
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

  final Database _db;

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
        (txn) => action(WriteTransaction._(txn)),
        label: label,
        actor: actor,
        requestId: requestId,
        onDuplicate: onDuplicate,
      );
    }
    return db.transaction((txn) => action(WriteTransaction._(txn)));
  }
}

DatabaseExecutor writeExecutor(WriteTransaction? transaction, Database db) =>
    transaction?._transaction ?? db;
