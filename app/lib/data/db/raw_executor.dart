import 'package:sqlite3/sqlite3.dart' as sqlite;

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
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAction? conflictAlgorithm,
  }) => Future.sync(
    () => _insert(_insertSql(table, values, conflictAlgorithm), [
      ...values.values,
    ]),
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
  }) => Future.sync(
    () => _select(
      _querySql(
        table,
        distinct: distinct,
        columns: columns,
        where: where,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      ),
      whereArgs,
    ),
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => Future.sync(() => _select(sql, arguments));

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAction? conflictAlgorithm,
  }) => Future.sync(
    () => _run(
      _updateSql(
        table,
        values,
        where: where,
        conflictAlgorithm: conflictAlgorithm,
      ),
      [...values.values, ...?whereArgs],
    ),
  );

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      Future.sync(() => _run(sql, arguments));

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      Future.sync(() => _run(_deleteSql(table, where: where), whereArgs));

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      Future.sync(() => _run(sql, arguments));

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

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

String _insertSql(
  String table,
  Map<String, Object?> values,
  ConflictAction? conflictAlgorithm,
) {
  final prefix = switch (conflictAlgorithm) {
    null || ConflictAction.abort => 'INSERT',
    ConflictAction.rollback => 'INSERT OR ROLLBACK',
    ConflictAction.fail => 'INSERT OR FAIL',
    ConflictAction.ignore => 'INSERT OR IGNORE',
    ConflictAction.replace => 'INSERT OR REPLACE',
  };
  if (values.isEmpty) return '$prefix INTO ${_quote(table)} DEFAULT VALUES';
  final columns = values.keys.map(_quote).join(', ');
  final placeholders = List.filled(values.length, '?').join(', ');
  return '$prefix INTO ${_quote(table)} ($columns) VALUES ($placeholders)';
}

String _updateSql(
  String table,
  Map<String, Object?> values, {
  String? where,
  ConflictAction? conflictAlgorithm,
}) {
  final prefix = switch (conflictAlgorithm) {
    null || ConflictAction.abort => 'UPDATE',
    ConflictAction.rollback => 'UPDATE OR ROLLBACK',
    ConflictAction.fail => 'UPDATE OR FAIL',
    ConflictAction.ignore => 'UPDATE OR IGNORE',
    ConflictAction.replace => 'UPDATE OR REPLACE',
  };
  final assignments = values.keys.map((key) => '${_quote(key)} = ?').join(', ');
  final buffer = StringBuffer('$prefix ${_quote(table)} SET $assignments');
  if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
  return buffer.toString();
}

String _deleteSql(String table, {String? where}) {
  final buffer = StringBuffer('DELETE FROM ${_quote(table)}');
  if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
  return buffer.toString();
}

String _querySql(
  String table, {
  bool? distinct,
  List<String>? columns,
  String? where,
  String? groupBy,
  String? having,
  String? orderBy,
  int? limit,
  int? offset,
}) {
  final buffer = StringBuffer('SELECT ');
  if (distinct == true) buffer.write('DISTINCT ');
  buffer.write(columns == null ? '*' : columns.map(_quote).join(', '));
  buffer.write(' FROM ${_quote(table)}');
  if (where != null && where.trim().isNotEmpty) buffer.write(' WHERE $where');
  if (groupBy != null && groupBy.trim().isNotEmpty) {
    buffer.write(' GROUP BY $groupBy');
  }
  if (having != null && having.trim().isNotEmpty) {
    buffer.write(' HAVING $having');
  }
  if (orderBy != null && orderBy.trim().isNotEmpty) {
    buffer.write(' ORDER BY $orderBy');
  }
  if (limit != null) buffer.write(' LIMIT $limit');
  if (offset != null) {
    if (limit == null) buffer.write(' LIMIT -1');
    buffer.write(' OFFSET $offset');
  }
  return buffer.toString();
}

/// 已持有 [RawExecutor] 的调用方继续使用 `.raw`，不必区分实现。
extension RawSelf on RawExecutor {
  RawExecutor get raw => this;
}

extension RawDatabaseSelf on RawDatabase {
  RawDatabase get rawDb => this;
}
