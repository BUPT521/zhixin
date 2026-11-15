import 'package:drift/drift.dart';

import '../guarded_database.dart';
import '../raw_executor.dart';
import 'app_database.dart';

/// 把 drift 的连接接到版本引擎与备份使用的 [RawExecutor] 上。
///
/// SQL 仍是引擎自己拼的原生语句，这里只负责执行、绑定参数与事务边界；
/// 执行器本身随恢复替换，仓库与页面持有的对象不变。
class DriftRawDatabase implements RawDatabase {
  DriftRawDatabase(this.database);

  final AppDatabase database;

  @override
  DatabaseConnectionUser get driftConnection => database;

  DriftRawExecutor get _executor => DriftRawExecutor(database);

  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) =>
      database.transaction(() => action(DriftRawExecutor(database)));

  @override
  Future<void> close() => database.close();

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _executor.execute(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _executor.rawInsert(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _executor.rawQuery(sql, arguments);
}

/// 单条语句与事务共用的执行器；事务内的对象由 drift 的 Transaction 提供。
class DriftRawExecutor implements RawExecutor {
  DriftRawExecutor(this._db);

  final DatabaseConnectionUser _db;

  @override
  DatabaseConnectionUser get driftConnection => _db;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _db.customStatement(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _db.customInsert(sql, variables: _variables(arguments));

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _db
      .customSelect(sql, variables: _variables(arguments))
      .get()
      .then((rows) => [for (final row in rows) row.data]);
}

List<Variable> _variables(List<Object?>? values) => [
  for (final value in values ?? const <Object?>[]) Variable(value),
];

/// Run generated statements through the same gate and transaction as raw SQL.
extension GeneratedRepositoryStatements on RawExecutor {
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase) query) {
    final executor = this;
    if (executor is GuardedDatabase) {
      return executor.readGenerated((active) => active.selectGenerated(query));
    }
    return query(_generatedDatabase);
  }

  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase) query) {
    final executor = this;
    if (executor is GuardedDatabase) {
      return executor.transaction((active) => query(active._generatedDatabase));
    }
    return query(_generatedDatabase);
  }

  AppDatabase get _generatedDatabase {
    final database = driftConnection;
    if (database is AppDatabase) return database;
    throw StateError('仓库查询需要 drift 主库连接');
  }
}
