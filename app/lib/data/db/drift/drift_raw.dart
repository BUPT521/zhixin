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
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAction? conflictAlgorithm,
  }) => _executor.insert(
    table,
    values,
    nullColumnHack: nullColumnHack,
    conflictAlgorithm: conflictAlgorithm,
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
  }) => _executor.query(
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
  ]) => _executor.rawQuery(sql, arguments);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAction? conflictAlgorithm,
  }) => _executor.update(
    table,
    values,
    where: where,
    whereArgs: whereArgs,
    conflictAlgorithm: conflictAlgorithm,
  );

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _executor.rawUpdate(sql, arguments);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _executor.delete(table, where: where, whereArgs: whereArgs);

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _executor.rawDelete(sql, arguments);
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
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAction? conflictAlgorithm,
  }) {
    final prefix = _insertPrefix(conflictAlgorithm);
    if (values.isEmpty) {
      return _db.customInsert('$prefix INTO ${_quote(table)} DEFAULT VALUES');
    }
    final columns = values.keys.map(_quote).join(', ');
    final placeholders = List.filled(values.length, '?').join(', ');
    return _db.customInsert(
      '$prefix INTO ${_quote(table)} ($columns) VALUES ($placeholders)',
      variables: _variables(values.values.toList()),
    );
  }

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
  }) {
    final buffer = StringBuffer('SELECT ');
    if (distinct == true) buffer.write('DISTINCT ');
    buffer.write(columns == null ? '*' : columns.map(_quote).join(', '));
    buffer.write(' FROM ${_quote(table)}');
    if (where != null && where.trim().isNotEmpty) {
      buffer.write(' WHERE $where');
    }
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
    return _db
        .customSelect(buffer.toString(), variables: _variables(whereArgs))
        .get()
        .then((rows) => [for (final row in rows) row.data]);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => _db
      .customSelect(sql, variables: _variables(arguments))
      .get()
      .then((rows) => [for (final row in rows) row.data]);

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAction? conflictAlgorithm,
  }) {
    if (values.isEmpty) return Future.value(0);
    final assignments = values.keys
        .map((key) => '${_quote(key)} = ?')
        .join(', ');
    final sql = StringBuffer(
      '${_updatePrefix(conflictAlgorithm)}${_quote(table)} SET $assignments',
    );
    if (where != null && where.trim().isNotEmpty) sql.write(' WHERE $where');
    return _db.customUpdate(
      sql.toString(),
      variables: _variables([...values.values, ...?whereArgs]),
      updateKind: UpdateKind.update,
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _db.customUpdate(
        sql,
        variables: _variables(arguments),
        updateKind: UpdateKind.update,
      );

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    final sql = StringBuffer('DELETE FROM ${_quote(table)}');
    if (where != null && where.trim().isNotEmpty) sql.write(' WHERE $where');
    return _db.customUpdate(
      sql.toString(),
      variables: _variables(whereArgs),
      updateKind: UpdateKind.delete,
    );
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _db.customUpdate(
        sql,
        variables: _variables(arguments),
        updateKind: UpdateKind.delete,
      );
}

List<Variable> _variables(List<Object?>? values) => [
  for (final value in values ?? const <Object?>[]) Variable(value),
];

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

String _insertPrefix(ConflictAction? action) => switch (action) {
  null || ConflictAction.abort => 'INSERT',
  ConflictAction.rollback => 'INSERT OR ROLLBACK',
  ConflictAction.fail => 'INSERT OR FAIL',
  ConflictAction.ignore => 'INSERT OR IGNORE',
  ConflictAction.replace => 'INSERT OR REPLACE',
};

String _updatePrefix(ConflictAction? action) => switch (action) {
  null || ConflictAction.abort => 'UPDATE ',
  ConflictAction.rollback => 'UPDATE OR ROLLBACK ',
  ConflictAction.fail => 'UPDATE OR FAIL ',
  ConflictAction.ignore => 'UPDATE OR IGNORE ',
  ConflictAction.replace => 'UPDATE OR REPLACE ',
};

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
