part of 'revision_engine.dart';

/// 远端提交：把另一台设备提交里的净变化写进当前事务，并按列记录本机被覆盖的
/// 修改。
///
/// 拥有者：泳道 S（ADR-0039 第 3.3 节）。

mixin RevisionRemoteMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  /// 把另一台设备提交里的净变化写进当前事务，供增量同步在本机应用远端提交。
  ///
  /// 远端提交已经由服务端按到达顺序排好，这里按原顺序应用：新增遇到本机已有
  /// 同一主键时按整行覆盖，更新遇到本机没有这一行时跳过，删除遇到没有这一行时
  /// 也跳过；外键检查延迟到事务提交，先写子行再写父行的顺序不会失败。返回因
  /// 本机状态对不上而跳过的条数，调用方只把它写进诊断记录，不中断整批同步。
  Future<int> applyChanges(
    RawExecutor txn,
    List<RevisionChange> changes,
  ) async {
    final schema = await self.tables(txn);
    await txn.execute('PRAGMA defer_foreign_keys = ON');
    var skipped = 0;
    for (final change in changes) {
      final table = schema[change.table];
      if (table == null) {
        throw FormatException('远端提交包含未知的表 ${change.table}');
      }
      final row = change.after ?? const <String, RevisionValue>{};
      final columns = [
        for (final column in row.keys)
          if (table.columns.contains(column) && column != table.primaryKey)
            column,
      ];
      final exists = await self._rowExists(txn, table, change.rowKey);
      switch (change.op) {
        case ChangeOp.insert:
          if (columns.isEmpty) {
            skipped++;
            continue;
          }
          if (exists) {
            await self._writeColumns(
              txn,
              table,
              rowKey: change.rowKey,
              columns: columns,
              row: row,
            );
          } else {
            await self._insertColumns(
              txn,
              table,
              rowKey: change.rowKey,
              columns: columns,
              row: row,
            );
          }
        case ChangeOp.update:
          if (!exists || columns.isEmpty) {
            skipped++;
            continue;
          }
          await self._writeColumns(
            txn,
            table,
            rowKey: change.rowKey,
            columns: columns,
            row: row,
          );
        case ChangeOp.delete:
          if (!exists) {
            skipped++;
            continue;
          }
          await txn.execute(
            'DELETE FROM ${_quote(table.name)} '
            'WHERE ${_quote(table.primaryKey)} = ?',
            [change.rowKey],
          );
      }
    }
    return skipped;
  }

  Future<bool> _rowExists(
    RawExecutor txn,
    RevisionTable table,
    String rowKey,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT 1 AS found FROM ${_quote(table.name)} '
      'WHERE ${_quote(table.primaryKey)} = ? LIMIT 1',
      [rowKey],
    );
    return rows.isNotEmpty;
  }

  Future<void> _insertColumns(
    RawExecutor txn,
    RevisionTable table, {
    required String rowKey,
    required List<String> columns,
    required TypedRow row,
  }) async {
    final names = [table.primaryKey, ...columns];
    final placeholders = List.filled(names.length, '?').join(', ');
    await txn.execute(
      'INSERT INTO ${_quote(table.name)} '
      '(${names.map(_quote).join(', ')}) VALUES ($placeholders)',
      [rowKey, for (final column in columns) row[column]!.sqliteValue],
    );
  }

  Future<void> _writeColumns(
    RawExecutor txn,
    RevisionTable table, {
    required String rowKey,
    required List<String> columns,
    required TypedRow row,
  }) async {
    final assignments = columns
        .map((column) => '${_quote(column)} = ?')
        .join(', ');
    await txn.execute(
      'UPDATE ${_quote(table.name)} SET $assignments '
      'WHERE ${_quote(table.primaryKey)} = ?',
      [for (final column in columns) row[column]!.sqliteValue, rowKey],
    );
  }
}
