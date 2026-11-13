import 'package:sqflite/sqflite.dart' as sqflite;

/// 写入冲突策略；语义与 SQLite 的 `OR ...` 一致。
enum ConflictAction { rollback, abort, fail, ignore, replace }

/// 版本引擎、备份与撤销使用的最小 SQL 执行器。
///
/// 方法名与参数沿用原来的 sqflite 形态，切换执行引擎时只换实现，不改 SQL。
abstract class RawExecutor {
  Future<void> execute(String sql, [List<Object?>? arguments]);

  Future<int> rawInsert(String sql, [List<Object?>? arguments]);

  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAction? conflictAlgorithm,
  });

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
  });

  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]);

  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAction? conflictAlgorithm,
  });

  Future<int> rawUpdate(String sql, [List<Object?>? arguments]);

  Future<int> delete(String table, {String? where, List<Object?>? whereArgs});

  Future<int> rawDelete(String sql, [List<Object?>? arguments]);
}

/// 可以自己开事务的执行器；引擎的整版恢复、命名版本与裁剪用到这里。
abstract class RawDatabase implements RawExecutor {
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action);
}

/// sqflite 实现：迁移期间让旧入口与旧测试继续跑同一套引擎代码。
class SqfliteRawExecutor implements RawExecutor {
  SqfliteRawExecutor(this._db);

  final sqflite.DatabaseExecutor _db;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      _db.execute(sql, arguments);

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      _db.rawInsert(sql, arguments);

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAction? conflictAlgorithm,
  }) => _db.insert(
    table,
    values,
    nullColumnHack: nullColumnHack,
    conflictAlgorithm: _mapConflict(conflictAlgorithm),
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
  }) => _db.query(
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
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _db.rawQuery(sql, arguments);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAction? conflictAlgorithm,
  }) => _db.update(
    table,
    values,
    where: where,
    whereArgs: whereArgs,
    conflictAlgorithm: _mapConflict(conflictAlgorithm),
  );

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _db.rawUpdate(sql, arguments);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _db.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _db.rawDelete(sql, arguments);
}

class SqfliteRawDatabase extends SqfliteRawExecutor implements RawDatabase {
  SqfliteRawDatabase(this._database) : super(_database);

  final sqflite.Database _database;

  @override
  Future<T> transaction<T>(Future<T> Function(RawExecutor txn) action) =>
      _database.transaction((txn) => action(SqfliteRawExecutor(txn)));
}

sqflite.ConflictAlgorithm? _mapConflict(ConflictAction? action) {
  if (action == null) return null;
  return switch (action) {
    ConflictAction.rollback => sqflite.ConflictAlgorithm.rollback,
    ConflictAction.abort => sqflite.ConflictAlgorithm.abort,
    ConflictAction.fail => sqflite.ConflictAlgorithm.fail,
    ConflictAction.ignore => sqflite.ConflictAlgorithm.ignore,
    ConflictAction.replace => sqflite.ConflictAlgorithm.replace,
  };
}

/// 在迁移期把 sqflite 的执行器直接接到原生 SQL 接口上。
extension SqfliteExecutorRaw on sqflite.DatabaseExecutor {
  RawExecutor get raw => SqfliteRawExecutor(this);
}

extension SqfliteDatabaseRaw on sqflite.Database {
  RawDatabase get rawDb => SqfliteRawDatabase(this);
}
