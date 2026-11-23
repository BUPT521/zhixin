part of 'revision_engine.dart';

/// 远端提交：把另一台设备提交里的净变化写进当前事务，并按列记录本机被覆盖的
/// 修改。
///
/// 拥有者：泳道 S（ADR-0039 第 3.3 节）。

/// 一条远端提交在本机应用之后的结果：因本机状态对不上而跳过的条数、把本机行
/// 改到下一个空号的条数，以及被覆盖的本机修改。冲突由调用方交给 `finishCommand`
/// 写进 `revision_conflict`；本机行的改号也被触发器和这次提交一起采集。
typedef RemoteApplyOutcome = ({
  int skipped,
  int adjusted,
  List<RevisionConflict> conflicts,
  List<RevisionChange> applied,
});

mixin RevisionRemoteMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  /// 把另一台设备提交里的净变化写进当前事务，供增量同步在本机应用远端提交。
  ///
  /// 远端提交已经由服务端按到达顺序排好，这里按原顺序应用。同步仍然是后到
  /// 覆盖先到：远端值一律写入本机，只在按列做三方比较发现本机也改过同一处时
  /// 记一条冲突，交给调用方随提交一起写进 `revision_conflict`，用户可以据此
  /// 把本机值作为新提交写回。`revisionBookkeepingColumns` 里的维护列（目前是
  /// `updated_at`）按合并驱动的规则处理：远端值照常写入，但不记冲突，冲突记录
  /// 只留用户看得懂的内容列（ADR-0040）。新增遇到本机已有同一主键时整行覆盖并
  /// 记冲突，更新遇到本机没有这一行时跳过并记冲突，删除遇到本机改过的行时先记下
  /// 本机整行再删除。外键检查延迟到事务提交，先写子行再写父行的顺序不会失败。
  ///
  /// 表结构里声明的列组（[revisionColumnGroups]）整组写入，跨列 CHECK 因此只
  /// 约束总是一起写入的列；表结构里声明的唯一键（[revisionUniqueKeys]）撞车时
  /// 按声明的处置执行：只表示顺序的列把本机行改到下一个空号，有含义的唯一键
  /// 跳过远端这一行并记一条 `unique_key_taken` 冲突（审查 S18）。
  ///
  /// 真正写进本机的格子同时登记进 `sync_shadow`：编号不大于应用之前本机 `HEAD`
  /// 的本机提交在这些格子上的改动作废，推送时按格去掉（ADR-0040）。
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
    // 应用这条远端提交之前的本机 HEAD：编号不大于它的本机提交在这个事务写进
    // 的格子上作废，推送时按格去掉（ADR-0040）。
    final uptoCommit = await self.headId(txn);
    var skipped = 0;
    final conflicts = <RevisionConflict>[];
    final appliedChanges = <RevisionChange>[];
    // 为了绕开唯一键而改号的本机行也登记进遮蔽：它们不来自远端的变化明细，
    // 但同样是这次提交写进本机的格子。
    final adjustedChanges = <RevisionChange>[];
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
          adjustedChanges,
        ),
        ChangeOp.update => await _applyRemoteUpdate(
          txn,
          table,
          change,
          conflicts,
          adjustedChanges,
        ),
        ChangeOp.delete => await _applyRemoteDelete(
          txn,
          table,
          change,
          conflicts,
        ),
      };
      if (!applied) {
        skipped++;
      } else {
        appliedChanges.add(change);
      }
    }
    appliedChanges.addAll(adjustedChanges);
    // 遮蔽行与这条远端提交在本机形成的提交同属一个事务：拉取成功、推送
    // 失败之后它仍然在库里，下一轮推送不会再把这些格子推回去。
    final shadows = RevisionShadows(txn);
    for (final change in appliedChanges) {
      await shadows.recordChange(change, uptoCommit: uptoCommit);
    }
    return (
      skipped: skipped,
      adjusted: adjustedChanges.length,
      conflicts: conflicts,
      applied: appliedChanges,
    );
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
    List<RevisionChange> adjusted,
  ) async {
    final after = change.after ?? const <String, RevisionValue>{};
    final columns = _remoteColumns(table, after);
    if (columns.isEmpty) return false;
    final current = await _readRemoteRow(txn, table, change.rowKey);
    if (current == null) {
      final writable = await _resolveUniqueKeys(
        txn,
        table,
        after,
        rowKey: change.rowKey,
        conflicts: conflicts,
        adjusted: adjusted,
      );
      if (!writable) return false;
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
      if (revisionBookkeepingColumns.contains(column)) return false;
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
  /// 然后写入远端值。列组里的其他列一起写入，跨列 CHECK 因此不会被半行更新
  /// 破坏（审查 S18）。
  Future<bool> _applyRemoteUpdate(
    RawExecutor txn,
    RevisionTable table,
    RevisionChange change,
    List<RevisionConflict> conflicts,
    List<RevisionChange> adjusted,
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
    final writable = await _resolveUniqueKeys(
      txn,
      table,
      {...current, ...after},
      rowKey: change.rowKey,
      conflicts: conflicts,
      adjusted: adjusted,
    );
    if (!writable) return false;
    final before = change.before ?? const <String, RevisionValue>{};
    for (final column in columns) {
      // 维护列（`updated_at`）按合并驱动处理：远端值照常写入，但不记冲突。
      // 两台设备改了同一行的不同内容列时，维护列几乎每次都会各写一次，记下来
      // 就是“更新时间被覆盖”这种用户看不懂的噪音（ADR-0040）。
      if (revisionBookkeepingColumns.contains(column)) continue;
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
      if (column == table.primaryKey ||
          !table.columns.contains(column) ||
          revisionBookkeepingColumns.contains(column)) {
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

  /// 检查远端这一行会撞上的非主键唯一约束，按 [revisionUniqueKeys] 的声明处置。
  ///
  /// 返回是否可以继续写入：有含义的唯一键被本机另一行占着时返回 false，这条
  /// 远端变化跳过并留下 `unique_key_taken` 冲突；只表示顺序的列则把本机那一行
  /// 改到下一个空号，改号随这次提交一起被采集，并登记进 [adjusted] 供遮蔽。
  Future<bool> _resolveUniqueKeys(
    RawExecutor txn,
    RevisionTable table,
    TypedRow row, {
    required String rowKey,
    required List<RevisionConflict> conflicts,
    required List<RevisionChange> adjusted,
  }) async {
    for (final rule in revisionUniqueKeys) {
      if (rule.table != table.name) continue;
      if (!rule.columns.every(row.containsKey)) continue;
      if (rule.columns.any(
        (column) =>
            row[column]!.type == RevisionValueType.nullValue ||
            row[column]!.value == null,
      )) {
        // SQLite 的唯一约束认为两个 NULL 互不相同，带空值的行不会撞车。
        continue;
      }
      final where = rule.columns
          .map((column) => '${_quote(column)} = ?')
          .join(' AND ');
      final values = [
        for (final column in rule.columns) row[column]!.sqliteValue,
      ];
      final rows = await txn.rawQuery(
        'SELECT * FROM ${_quote(table.name)} WHERE $where '
        'AND ${_quote(table.primaryKey)} != ? LIMIT 2',
        [...values, rowKey],
      );
      if (rows.isEmpty) continue;
      final taken = typedRow(rows.first);
      switch (rule.policy) {
        case RevisionUniqueKeyPolicy.skipRemote:
          conflicts.add(
            RevisionConflict(
              table: table.name,
              rowKey: rowKey,
              reason: RevisionConflict.uniqueKeyTaken,
              local: taken,
              remoteAfter: row,
            ),
          );
          return false;
        case RevisionUniqueKeyPolicy.renumberLocal:
          await _renumberLocalRow(txn, table, rule, row, taken, adjusted);
      }
    }
    return true;
  }

  /// 把占用唯一键的本机行改到同一前缀下的下一个空号，并留下可供遮蔽的变更。
  Future<void> _renumberLocalRow(
    RawExecutor txn,
    RevisionTable table,
    RevisionUniqueKey rule,
    TypedRow remote,
    TypedRow taken,
    List<RevisionChange> adjusted,
  ) async {
    final orderColumn = rule.columns.last;
    final prefix = rule.columns.sublist(0, rule.columns.length - 1);
    final prefixWhere = prefix.isEmpty
        ? ''
        : ' WHERE ${prefix.map((column) => '${_quote(column)} = ?').join(' AND ')}';
    final maxRows = await txn.rawQuery(
      'SELECT MAX(${_quote(orderColumn)}) AS max_value '
      'FROM ${_quote(table.name)}$prefixWhere',
      [for (final column in prefix) remote[column]!.sqliteValue],
    );
    final maxValue = maxRows.first['max_value'] as int? ?? 0;
    final next = maxValue + 1;
    final localKey = taken[table.primaryKey]!.sqliteValue;
    await txn.execute(
      'UPDATE ${_quote(table.name)} SET ${_quote(orderColumn)} = ? '
      'WHERE ${_quote(table.primaryKey)} = ?',
      [next, localKey],
    );
    final after = {...taken, orderColumn: RevisionValue.of(next)};
    adjusted.add(
      RevisionChange(
        commitId: 0,
        seq: adjusted.length + 1,
        table: table.name,
        rowKey: '$localKey',
        op: ChangeOp.update,
        before: taken,
        after: after,
      ),
    );
  }

  /// 远端提交里要写入本机的列：只保留本机表结构里有的列，主键单独处理。
  ///
  /// 有列落在 [revisionColumnGroups] 的列组里时，同组的其他列也一起写入，
  /// 跨列 CHECK 因此只约束总是一起写入的列（审查 S18）。
  List<String> _remoteColumns(RevisionTable table, TypedRow row) {
    final source = {
      for (final column in row.keys)
        if (table.columns.contains(column) && column != table.primaryKey)
          column,
    };
    final expanded = expandedRevisionColumns(table.name, source);
    final columns = [
      for (final column in expanded)
        if (row.containsKey(column) && table.columns.contains(column)) column,
    ]..sort();
    return columns;
  }

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
