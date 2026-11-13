import 'dart:async';

import '../revisions/revision_engine.dart';
import '../revisions/revision_models.dart';
import 'database_gate.dart';
import 'raw_executor.dart';

/// 把整库访问收进 [DatabaseGate]：读共享，写、事务与关闭独占（01 第 7 章）。
///
/// 仓库与页面只拿这一个对象，不直接持有连接：恢复流程替换连接之后，[resolve]
/// 指向新连接，排队的写入在新库上继续，不会打到已经关闭的旧库。
///
/// 每次独立写入或命令事务由 [RevisionEngine] 建立提交上下文，业务行与版本
/// 明细一起提交；事务回调里再次写入直接使用本次事务，不再排队，也不会另开
/// 一个提交。
class GuardedDatabase implements RawDatabase {
  GuardedDatabase({
    required this.gate,
    required this.resolve,
    this.revisions,
    this.defaultAction = '数据写入',
  });

  final DatabaseGate gate;

  /// 取当前连接；恢复替换期间由调用方切到新连接。
  final RawDatabase Function() resolve;

  /// 数据版本引擎；为空的旧测试入口只执行原始 SQL。
  RevisionEngine? revisions;

  /// 没有显式业务动作时的提交说明。
  final String defaultAction;

  static final Object _txnScope = Object();
  static final Object _labelScope = Object();
  static final Object _actorScope = Object();

  RawDatabase get _db => resolve();

  RawExecutor? get _currentTxn => Zone.current[_txnScope] as RawExecutor?;

  /// 版本引擎、备份与撤销使用的执行器就是本对象本身。
  RawExecutor get raw => this;

  /// 需要自己开事务的引擎方法也拿本对象；事务仍经 [gate] 独占。
  RawDatabase get rawDb => this;

  /// 关闭连接：等正在进行的读写结束；恢复流程里已经在独占区，直接执行。
  @override
  Future<void> close() => gate.exclusive(() => _db.close());

  /// 事务一律按独占执行：事务里通常要写，读到的也必须是同一时刻的状态。
  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) =>
      _run(action);

  /// 带业务动作标签的命令；一次动作修改多张表时仍只形成一个提交。
  ///
  /// [requestId] 相同的第二次调用不再执行写入；提供 [onDuplicate] 时由调用方
  /// 把原提交还原成同样的结果，否则抛出 [RevisionDuplicateRequest]。
  Future<T> command<T>(
    Future<T> Function(RawExecutor txn) action, {
    required String label,
    String actor = 'user',
    String? requestId,
    T Function(RevisionCommit commit)? onDuplicate,
  }) => _run(
    action,
    label: label,
    actor: actor,
    requestId: requestId,
    onDuplicate: onDuplicate,
  );

  Future<T> _run<T>(
    Future<T> Function(RawExecutor txn) action, {
    String? label,
    String actor = 'user',
    String? requestId,
    T Function(RevisionCommit commit)? onDuplicate,
  }) {
    final active = _currentTxn;
    if (active != null) return action(active);
    return gate.exclusive(() {
      final engine = revisions;
      if (engine == null) {
        return _db.transaction(
          (txn) => runZoned(
            () => action(txn),
            zoneValues: {
              _labelScope: label ?? defaultAction,
              _actorScope: actor,
            },
          ),
        );
      }
      return _db.transaction((txn) async {
        if (requestId != null) {
          final existing = await engine.commitByRequest(txn, requestId);
          if (existing != null) {
            if (onDuplicate != null) return onDuplicate(existing);
            throw RevisionDuplicateRequest(existing);
          }
        }
        final commitId = await engine.beginCommand(txn, requestId: requestId);
        return runZoned(
          () async {
            final result = await action(txn);
            await engine.finishCommand(
              txn,
              commitId,
              action: label ?? defaultAction,
              actor: actor,
              requestId: requestId,
            );
            return result;
          },
          zoneValues: {
            _txnScope: txn,
            _labelScope: label ?? defaultAction,
            _actorScope: actor,
          },
        );
      });
    });
  }

  /// 独立的写语句各自形成一个提交；事务里的写直接使用本次事务。
  Future<T> _write<T>(Future<T> Function(RawExecutor executor) action) {
    final active = _currentTxn;
    if (active != null) return action(active);
    return transaction(action);
  }

  /// 版本化表不接受 `REPLACE`：它会隐式删除冲突行，旧行可能不触发删除采集。
  void _guardReplace(String table, ConflictAction? algorithm) {
    if (algorithm != ConflictAction.replace) return;
    if (versionedTableNames.contains(table)) {
      throw ArgumentError(
        '版本化表 $table 不能使用 REPLACE，请改用 insert、update 或 UPSERT',
      );
    }
  }

  bool _rawReplaceOnVersioned(String sql) {
    final normalized = sql.trimLeft().toUpperCase();
    final replace =
        normalized.startsWith('REPLACE') ||
        RegExp(r'^INSERT\s+OR\s+REPLACE').hasMatch(normalized);
    if (!replace) return false;
    final lower = sql.toLowerCase();
    return versionedTableNames.any(
      (table) => RegExp('\\b${RegExp.escape(table)}\\b').hasMatch(lower),
    );
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    if (_rawReplaceOnVersioned(sql)) {
      throw ArgumentError('版本化表不能使用 REPLACE，请改用 insert、update 或 UPSERT');
    }
    return _write((executor) => executor.execute(sql, arguments));
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) {
    if (_rawReplaceOnVersioned(sql)) {
      throw ArgumentError('版本化表不能使用 REPLACE，请改用 insert、update 或 UPSERT');
    }
    return _write((executor) => executor.rawInsert(sql, arguments));
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAction? conflictAlgorithm,
  }) {
    _guardReplace(table, conflictAlgorithm);
    return _write(
      (executor) => executor.insert(
        table,
        values,
        nullColumnHack: nullColumnHack,
        conflictAlgorithm: conflictAlgorithm,
      ),
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _write((executor) => executor.rawUpdate(sql, arguments));

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAction? conflictAlgorithm,
  }) {
    _guardReplace(table, conflictAlgorithm);
    return _write(
      (executor) => executor.update(
        table,
        values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm,
      ),
    );
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _write((executor) => executor.rawDelete(sql, arguments));

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _write(
        (executor) =>
            executor.delete(table, where: where, whereArgs: whereArgs),
      );

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => gate.shared(
    () => _db.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => gate.shared(() => _db.rawQuery(sql, arguments));
}
