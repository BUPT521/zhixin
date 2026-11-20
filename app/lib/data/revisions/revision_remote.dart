part of 'revision_engine.dart';

/// 远端提交：把另一台设备提交里的净变化写进当前事务，并按列记录本机被覆盖的
/// 修改。
///
/// 拥有者：泳道 S（ADR-0039 第 3.3 节）。

/// 一条远端提交在本机应用之后的结果：因本机状态对不上而跳过的条数，以及被
/// 覆盖的本机修改。冲突由调用方交给 `finishCommand` 写进 `revision_conflict`，
/// 这次提交的 `conflict_count` 随之更新。
typedef RemoteApplyOutcome = ({int skipped, List<RevisionConflict> conflicts});

mixin RevisionRemoteMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  /// 把另一台设备提交里的净变化写进当前事务，供增量同步在本机应用远端提交。
  ///
  /// 远端提交已经由服务端按到达顺序排好，这里按原顺序应用。同步仍然是后到
  /// 覆盖先到：远端值一律写入本机，只在按列做三方比较发现本机也改过同一处时
  /// 记一条冲突，交给调用方随提交一起写进 `revision_conflict`，用户可以据此
  /// 把本机值作为新提交写回。新增遇到本机已有同一主键时整行覆盖并记冲突，
  /// 更新遇到本机没有这一行时跳过并记冲突，删除遇到本机改过的行时先记下本机
  /// 整行再删除。外键检查延迟到事务提交，先写子行再写父行的顺序不会失败。
  ///
  /// 返回因本机状态对不上而跳过的条数，调用方只把它写进诊断记录，不中断整批
  /// 同步。冲突与提交行一起落库，所以一条远端提交的所有变化都被跳过时不会形成
  /// 提交，也就没有可挂载冲突的提交行；这种情况只返回跳过条数。
  Future<RemoteApplyOutcome> applyChanges(
    RawExecutor txn,
    List<RevisionChange> changes,
  ) async {
    final schema = await self.tables(txn);
    await txn.execute('PRAGMA defer_foreign_keys = ON');
    var skipped = 0;
    final conflicts = <RevisionConflict>[];
    for (final change in changes) {
      final table = schema[change.table];
      if (table == null) {
        throw FormatException('远端提交包含未知的表 ${change.table}');
      }
      final applied = switch (change.op) {
        ChangeOp.insert => await _applyRemoteInsert(
          txn,
          table,
          change,
          conflicts,
        ),
        ChangeOp.update => await _applyRemoteUpdate(
          txn,
          table,
          change,
          conflicts,
        ),
        ChangeOp.delete => await _applyRemoteDelete(
          txn,
          table,
          change,
          conflicts,
        ),
      };
      if (!applied) skipped++;
    }
    return (skipped: skipped, conflicts: conflicts);
  }

  /// 把一条冲突记录里保存的本机值写回当前事务，返回是否写了行。
  ///
  /// 并发更新只写冲突列，新增撞上本机已有主键时写回被覆盖的整行，远端删除
  /// 本机改过的行时按本机保存的整行重新插入。本机已经删掉那一行
  /// （`deleted_locally`）时没有可以写回的值，返回 false。
  Future<bool> restoreConflictLocal(
    RawExecutor txn,
    RevisionConflict conflict,
  ) async {
    final schema = await self.tables(txn);
    final table = schema[conflict.table];
    if (table == null) return false;
    final columns = [
      for (final column in conflict.local.keys)
        if (table.columns.contains(column) && column != table.primaryKey)
          column,
    ];
    if (columns.isEmpty) return false;
    final current = await _readRemoteRow(txn, table, conflict.rowKey);
    if (current != null) {
      await _writeColumns(
        txn,
        table,
        rowKey: conflict.rowKey,
        columns: columns,
        row: conflict.local,
      );
      return true;
    }
    if (conflict.reason != RevisionConflict.deletedRemotelyModified) {
      return false;
    }
    await _insertColumns(
      txn,
      table,
      rowKey: conflict.rowKey,
      columns: columns,
      row: conflict.local,
    );
    return true;
  }

  /// 远端新增：本机没有这一行就直接插入；已经有同一主键时按整行比较，内容
  /// 不同记 `insert_collision`，然后把远端整行覆盖上去。
  Future<bool> _applyRemoteInsert(
    RawExecutor txn,
    RevisionTable table,
    RevisionChange change,
    List<RevisionConflict> conflicts,
  ) async {
    final after = change.after ?? const <String, RevisionValue>{};
    final columns = _remoteColumns(table, after);
    if (columns.isEmpty) return false;
    final current = await _readRemoteRow(txn, table, change.rowKey);
    if (current == null) {
      await _insertColumns(
        txn,
        table,
        rowKey: change.rowKey,
        columns: columns,
        row: after,
      );
      return true;
    }
    final differs = columns.any((column) {
      final local = current[column];
      return local == null || !local.equals(after[column]!);
    });
    if (!differs) return true;
    conflicts.add(
      RevisionConflict(
        table: table.name,
        rowKey: change.rowKey,
        reason: RevisionConflict.insertCollision,
        local: current,
        remoteBefore: change.before,
        remoteAfter: after,
      ),
    );
    await _writeColumns(
      txn,
      table,
      rowKey: change.rowKey,
      columns: columns,
      row: after,
    );
    return true;
  }

  /// 远端更新：本机没有这一行时记 `deleted_locally` 并跳过写入；行存在时按列
  /// 比较本机当前值，既不是远端旧值也不是远端新值的列记 `concurrent_update`，
  /// 然后写入远端值。
  Future<bool> _applyRemoteUpdate(
    RawExecutor txn,
    RevisionTable table,
    RevisionChange change,
    List<RevisionConflict> conflicts,
  ) async {
    final after = change.after ?? const <String, RevisionValue>{};
    final columns = _remoteColumns(table, after);
    if (columns.isEmpty) return false;
    final current = await _readRemoteRow(txn, table, change.rowKey);
    if (current == null) {
      conflicts.add(
        RevisionConflict(
          table: table.name,
          rowKey: change.rowKey,
          reason: RevisionConflict.deletedLocally,
          // 本机已经删掉这一行，没有可以写回的本机值；local 存远端的新值，
          // 只作界面说明用的参考。
          local: after,
          remoteBefore: change.before,
          remoteAfter: after,
        ),
      );
      return false;
    }
    final before = change.before ?? const <String, RevisionValue>{};
    for (final column in columns) {
      final local = current[column] ?? RevisionValue.of(null);
      final remoteAfter = after[column]!;
      final remoteBefore = before[column];
      if (remoteBefore != null && local.equals(remoteBefore)) continue;
      if (local.equals(remoteAfter)) continue;
      conflicts.add(
        RevisionConflict(
          table: table.name,
          rowKey: change.rowKey,
          column: column,
          reason: RevisionConflict.concurrentUpdate,
          local: {column: local},
          remoteBefore: change.before,
          remoteAfter: after,
        ),
      );
    }
    await _writeColumns(
      txn,
      table,
      rowKey: change.rowKey,
      columns: columns,
      row: after,
    );
    return true;
  }

  /// 远端删除：本机没有这一行时跳过；行存在时与远端旧值比较，有列不同记
  /// `deleted_remotely_modified`，然后照常删除。
  Future<bool> _applyRemoteDelete(
    RawExecutor txn,
    RevisionTable table,
    RevisionChange change,
    List<RevisionConflict> conflicts,
  ) async {
    final current = await _readRemoteRow(txn, table, change.rowKey);
    if (current == null) return false;
    final before = change.before ?? const <String, RevisionValue>{};
    final modified = before.keys.any((column) {
      if (column == table.primaryKey || !table.columns.contains(column)) {
        return false;
      }
      final local = current[column];
      return local == null || !local.equals(before[column]!);
    });
    if (modified) {
      conflicts.add(
        RevisionConflict(
          table: table.name,
          rowKey: change.rowKey,
          reason: RevisionConflict.deletedRemotelyModified,
          local: current,
          remoteBefore: change.before,
          // 删除的远端提交没有新行，冲突表这一列不可空，写空对象表示删除。
          remoteAfter: change.after ?? const <String, RevisionValue>{},
        ),
      );
    }
    await txn.execute(
      'DELETE FROM ${_quote(table.name)} '
      'WHERE ${_quote(table.primaryKey)} = ?',
      [change.rowKey],
    );
    return true;
  }

  /// 远端提交里要写入本机的列：只保留本机表结构里有的列，主键单独处理。
  List<String> _remoteColumns(RevisionTable table, TypedRow row) => [
    for (final column in row.keys)
      if (table.columns.contains(column) && column != table.primaryKey) column,
  ];

  /// 读一行当前值；行不存在时返回空。
  Future<TypedRow?> _readRemoteRow(
    RawExecutor txn,
    RevisionTable table,
    String rowKey,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT * FROM ${_quote(table.name)} '
      'WHERE ${_quote(table.primaryKey)} = ? LIMIT 1',
      [rowKey],
    );
    return rows.isEmpty ? null : typedRow(rows.first);
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
