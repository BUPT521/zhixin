import 'package:drift/drift.dart' show DatabaseConnectionUser;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// 版本引擎、备份与撤销使用的最小 SQL 执行器。
///
/// 只保留执行语句、读回行与开事务三件事；按表名读写由 [sql.dart] 的辅助函数
/// 组装语句，仓库读写走 drift 生成查询（ADR-0021）。
abstract class RawExecutor {
  /// 生成代码使用的 drift 连接；只读副本等实现返回空。
  ///
  /// 仓库层迁进 `.drift` 文件之后，生成的查询方法要在同一个连接上执行，因此
  /// 从这里取连接，而不是另开一个 [RawExecutor]（ADR-0011 第 4 条）。
  DatabaseConnectionUser? get driftConnection => null;

  Future<void> execute(String sql, [List<Object?>? arguments]);

  Future<int> rawInsert(String sql, [List<Object?>? arguments]);

  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]);
}

/// 可以自己开事务的执行器；引擎的整版恢复、命名版本与裁剪用到这里。
abstract class RawDatabase implements RawExecutor {
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action);

  Future<void> close();
}

/// 只读打开一份库副本：备份、恢复校验与版本包都只读，不需要写入权限。
///
/// 只读打开不会为文件建回滚日志，临时目录里的副本因此可以直接删除。
RawDatabase openReadOnlyDatabase(String path) => SqliteRawDatabase(
  sqlite.sqlite3.open(path, mode: sqlite.OpenMode.readOnly),
);

/// 把 `package:sqlite3` 的连接接到 [RawDatabase] 上。
///
/// 真机的库文件由 drift 打开，副本由 [sqlite.sqlite3] 打开，两者共用这一个
/// 实现，SQL 与参数写法在两条路径上一致。
class SqliteRawDatabase implements RawDatabase {
  SqliteRawDatabase(this._db);

  final sqlite.Database _db;

  /// 只读副本走 sqlite3，没有 drift 连接，生成查询不在这里执行。
  @override
  DatabaseConnectionUser? get driftConnection => null;

  /// 执行一条语句并返回受影响的行数；回调在真实错误时抛出。
  int _run(String sql, [List<Object?>? arguments]) {
    final statement = _db.prepare(sql);
    try {
      if (arguments != null && arguments.isNotEmpty) {
        statement.execute(arguments);
      } else {
        statement.execute();
      }
      return _db.updatedRows;
    } finally {
      statement.close();
    }
  }

  int _insert(String sql, List<Object?>? arguments) {
    _run(sql, arguments);
    return _db.lastInsertRowId;
  }

  List<Map<String, Object?>> _select(String sql, List<Object?>? arguments) {
    final statement = _db.prepare(sql);
    try {
      final result = arguments == null
          ? statement.select()
          : statement.select(arguments);
      final rows = <Map<String, Object?>>[];
      for (final row in result) {
        rows.add({for (final key in row.keys) key: row[key]});
      }
      return rows;
    } finally {
      statement.close();
    }
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      Future.sync(() => _run(sql, arguments));

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      Future.sync(() => _insert(sql, arguments));

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => Future.sync(() => _select(sql, arguments));

  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) async {
    _run('BEGIN IMMEDIATE');
    try {
      final result = await action(this);
      _run('COMMIT');
      return result;
    } catch (_) {
      _run('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> close() async => _db.close();
}
