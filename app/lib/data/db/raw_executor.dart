import 'package:drift/drift.dart' show DatabaseConnectionUser;

import 'drift/app_database.dart';

import 'package:sqlite3/sqlite3.dart' as sqlite;

/// 版本引擎、备份与撤销使用的最小 SQL 执行器。
///
/// 只保留执行语句、读回行与开事务三件事；按表名读写由 [sql.dart] 的辅助函数
/// 组装语句，仓库读写走 drift 生成查询（ADR-0021）。
/// 原生写语句的类别：语句前缀决定 `execute` 用什么方式执行、返回什么。
enum SqlStatementKind {
  /// 插入（含 `INSERT OR REPLACE` 与 `REPLACE`）：返回新行的编号。
  insert,

  /// 更新：返回受影响的行数。
  update,

  /// 删除：返回受影响的行数。
  delete,

  /// 建表、`PRAGMA`、`VACUUM` 等没有行数概念的语句：返回 0。
  other,
}

/// 按语句开头的关键字给原生语句分类；前导空白不影响判断。
///
/// 两条实现（drift 连接与只读副本用的 `sqlite3`）都按这一个分类分派，
/// 返回值语义因此只有一份定义。
SqlStatementKind sqlStatementKind(String sql) {
  final head = sql.trimLeft().toUpperCase();
  if (head.startsWith('INSERT') || head.startsWith('REPLACE')) {
    return SqlStatementKind.insert;
  }
  if (head.startsWith('UPDATE')) return SqlStatementKind.update;
  if (head.startsWith('DELETE')) return SqlStatementKind.delete;
  return SqlStatementKind.other;
}

abstract class RawExecutor {
  /// 生成代码使用的 drift 连接；只读副本等实现返回空。
  ///
  /// 仓库层迁进 `.drift` 文件之后，生成的查询方法要在同一个连接上执行，因此
  /// 从这里取连接，而不是另开一个 [RawExecutor]（ADR-0011 第 4 条）。
  DatabaseConnectionUser? get driftConnection => null;

  /// 执行一条语句；插入返回新行编号，更新与删除返回受影响的行数，其余返回 0。
  ///
  /// 行号必须在同一条语句之后立刻读回：命令事务在提交收尾时还会写入版本
  /// 明细，晚一步读到的就是明细行的编号。
  Future<int> execute(String sql, [List<Object?>? arguments]);

  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]);

  /// 在同一个连接上执行 drift 生成查询；只读副本不支持，使用时抛错。
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query);

  /// 在同一个连接上执行生成查询，并形成一个提交。
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query);
}

/// 取执行器背后的 drift 主库；只读副本没有这个连接。
AppDatabase requireAppDatabase(RawExecutor executor) {
  final connection = executor.driftConnection;
  if (connection is AppDatabase) return connection;
  throw StateError('仓库查询需要 drift 主库连接');
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

  /// 按 [sqlStatementKind] 分派：插入取新行号，更新与删除取受影响行数，其他
  /// 语句没有行数概念，返回 0。
  ///
  /// 受影响行数要在语句执行之后立刻读回，与其他语句的返回路径分开：
  /// `sqlite3` 的 `updatedRows` 不会在 DDL 之后复位，混用会把上一条语句的
  /// 行数当成这一条的结果。
  int _runAndReport(String sql, List<Object?>? arguments) {
    final kind = sqlStatementKind(sql);
    final affected = _run(sql, arguments);
    return switch (kind) {
      SqlStatementKind.insert => _db.lastInsertRowId,
      SqlStatementKind.update || SqlStatementKind.delete => affected,
      SqlStatementKind.other => 0,
    };
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
  Future<int> execute(String sql, [List<Object?>? arguments]) =>
      Future.sync(() => _runAndReport(sql, arguments));

  @override
  Future<T> selectGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      throw StateError('只读副本不执行仓库查询');

  @override
  Future<T> writeGenerated<T>(Future<T> Function(AppDatabase db) query) =>
      throw StateError('只读副本不执行仓库查询');

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
