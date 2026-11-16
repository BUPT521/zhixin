import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../raw_executor.dart';
import 'app_database.dart';

/// 把 drift 的连接接到版本引擎与备份使用的 [RawExecutor] 上。
///
/// SQL 仍是引擎自己拼的原生语句，这里只负责执行、绑定参数与事务边界；
/// 执行器本身随恢复替换，仓库与页面持有的对象不变。
class DriftRawDatabase implements RawDatabase {
  DriftRawDatabase(this.database, {this.connection});

  final AppDatabase database;

  /// 打开库时持有的底层连接；由这里关闭，见 [close]。
  final sqlite.Database? connection;

  @override
  DatabaseConnectionUser get driftConnection => database;

  DriftRawExecutor get _executor => DriftRawExecutor(database);

  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) =>
      database.transaction(() => action(DriftRawExecutor(database)));

  /// 关库：先同步释放底层 SQLite 连接，再走 drift 的关闭流程。
  ///
  /// drift 的关闭要先关流查询、再关执行器，每一步都在微任务里接着走；页面
  /// 退出与测试收尾时这些微任务可能不再推进，文件就会一直被占着。底层连接
  /// 本身是同步关闭的，先关它，后面几步即使没走完也不会留下句柄。
  @override
  Future<void> close() async {
    try {
      final connection = this.connection;
      if (connection != null) connection.close();
    } catch (_) {
      // 已经关过：交给下面的 drift 关闭流程处理。
    }
    await database.close();
  }

  @override
  Future<int> execute(String sql, [List<Object?>? arguments]) =>
      _executor.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _executor.rawQuery(sql, arguments);

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      query(database);

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      database.transaction(() => query(database));
}

/// 单条语句与事务共用的执行器；事务内的对象由 drift 的 Transaction 提供。
class DriftRawExecutor implements RawExecutor {
  DriftRawExecutor(this._db);

  final DatabaseConnectionUser _db;

  @override
  DatabaseConnectionUser get driftConnection => _db;

  @override
  /// drift 的 customInsert 在执行完语句后立刻读回行号；其他语句返回受影响行数。
  Future<int> execute(String sql, [List<Object?>? arguments]) =>
      _db.customInsert(sql, variables: _variables(arguments));

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _db
      .customSelect(sql, variables: _variables(arguments))
      .get()
      .then((rows) => [for (final row in rows) row.data]);

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      query(requireAppDatabase(this));

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      query(requireAppDatabase(this));
}

List<Variable> _variables(List<Object?>? values) => [
  for (final value in values ?? const <Object?>[]) Variable(value),
];
