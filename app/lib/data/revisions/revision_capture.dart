part of 'revision_engine.dart';

/// 采集侧：安装暂存表与触发器，读取暂存行并合并成一次提交的净变化。
///
/// 拥有者：泳道 A（ADR-0039 第 3.3 节）。私有成员与同库其他文件共享。

/// 创建采集暂存表、触发器和版本上下文；打开库时执行，重复执行保持幂等。
Future<void> installRevisionSchema(
  RawDatabase db,
  RevisionEngine engine,
) async {
  final schema = await engine.tables(db);
  final existing = await selectRows(
    db,
    'sqlite_master',
    columns: ['name'],
    where: "type = 'trigger' AND name NOT LIKE 'sqlite_%'",
  );
  // 打开库时清除原有触发器，再按当前代码重建。
  for (final row in existing) {
    final name = row['name']! as String;
    await db.execute('DROP TRIGGER IF EXISTS "$name"');
  }
  for (final table in schema.values) {
    final stage = table.stageTable;
    final columns = <String>[
      'seq INTEGER PRIMARY KEY AUTOINCREMENT',
      'commit_id INTEGER NOT NULL',
      'row_key TEXT NOT NULL',
      'op TEXT NOT NULL',
      for (final column in table.columns) ...[
        _quote('o_$column'),
        _quote('n_$column'),
      ],
    ];
    await db.execute(
      'CREATE TABLE IF NOT EXISTS "$stage" (${columns.join(', ')})',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS "idx_${stage}_commit" '
      'ON "$stage"(commit_id, seq)',
    );
    await _createTriggers(db, table);
  }

  await insertRow(db, 'revision_context', {
    'id': 1,
    'active_commit': null,
    'capturing': 0,
    'suppress': 0,
  }, ignore: true);
  await insertRow(db, 'revision_sequence', {
    'id': 1,
    'next_commit': 1,
  }, ignore: true);
}

Future<void> _createTriggers(RawDatabase db, RevisionTable table) async {
  final q = _quote;
  final stage = q(table.stageTable);
  final source = q(table.name);
  final when =
      '(SELECT active_commit FROM revision_context WHERE id = 1) IS NOT NULL '
      'AND (SELECT suppress FROM revision_context WHERE id = 1) = 0';
  final allOld = table.columns.map((c) => q('o_$c')).join(', ');
  final allNew = table.columns.map((c) => q('n_$c')).join(', ');
  final oldValues = table.columns.map((c) => 'OLD.${q(c)}').join(', ');
  final newValues = table.columns.map((c) => 'NEW.${q(c)}').join(', ');
  final key = 'CAST(NEW.${q(table.primaryKey)} AS TEXT)';
  final oldKey = 'CAST(OLD.${q(table.primaryKey)} AS TEXT)';

  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_insert" AFTER INSERT ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (commit_id, row_key, op, $allOld, $allNew) '
    'VALUES ((SELECT active_commit FROM revision_context WHERE id = 1), '
    '$key, \'insert\', ${List.filled(table.columns.length, 'NULL').join(', ')}, '
    '$newValues); END',
  );
  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_update" AFTER UPDATE ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (commit_id, row_key, op, $allOld, $allNew) '
    'VALUES ((SELECT active_commit FROM revision_context WHERE id = 1), '
    '$key, \'update\', $oldValues, $newValues); END',
  );
  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_delete" AFTER DELETE ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (commit_id, row_key, op, $allOld, $allNew) '
    'VALUES ((SELECT active_commit FROM revision_context WHERE id = 1), '
    '$oldKey, \'delete\', $oldValues, '
    '${List.filled(table.columns.length, 'NULL').join(', ')}); END',
  );
}

mixin RevisionCaptureMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  /// 清空本次命令留下的暂存行。
  Future<void> _clearStage(RawExecutor txn, int commitId) async {
    final schema = await self.tables(txn);
    for (final table in schema.values) {
      await deleteRows(
        txn,
        table.stageTable,
        where: 'commit_id = ?',
        whereArgs: [commitId],
      );
    }
  }

  /// 把暂存行按“表名＋主键”合并成净变化：插入记修改后整行，删除记删除前
  /// 整行，修改只记变化列；同一次命令里先插入再删除的行不产生变化。
  Future<List<RevisionChange>> _collect(RawExecutor txn, int commitId) async {
    final schema = await self.tables(txn);
    final result = <RevisionChange>[];
    var seq = 1;
    for (final table in schema.values) {
      final rows = await selectRows(
        txn,
        table.stageTable,
        where: 'commit_id = ?',
        whereArgs: [commitId],
        orderBy: 'seq',
      );
      if (rows.isEmpty) continue;
      final groups = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final key = row['row_key']! as String;
        groups.putIfAbsent(key, () => []).add(row);
      }
      for (final entry in groups.entries) {
        final group = entry.value;
        final first = group.first;
        final last = group.last;
        final firstOp = ChangeOp.fromValue(first['op']! as String);
        final lastOp = ChangeOp.fromValue(last['op']! as String);
        TypedRow? before;
        TypedRow? after;
        if (firstOp != ChangeOp.insert) {
          before = self._sideRow(first, 'o_', table.columns);
        }
        if (lastOp != ChangeOp.delete) {
          after = self._sideRow(last, 'n_', table.columns);
        }
        if (before == null && after == null) continue;
        if (before != null && after != null) {
          final changed = changedColumns(before, after);
          if (changed.isEmpty) continue;
          result.add(
            RevisionChange(
              commitId: commitId,
              seq: seq++,
              table: table.name,
              rowKey: entry.key,
              op: ChangeOp.update,
              before: projectColumns(before, changed),
              after: projectColumns(after, changed),
            ),
          );
          continue;
        }
        result.add(
          RevisionChange(
            commitId: commitId,
            seq: seq++,
            table: table.name,
            rowKey: entry.key,
            op: before == null ? ChangeOp.insert : ChangeOp.delete,
            before: before,
            after: after,
          ),
        );
      }
    }
    return result;
  }

  TypedRow _sideRow(
    Map<String, Object?> stage,
    String prefix,
    List<String> columns,
  ) => {
    for (final column in columns)
      column: RevisionValue.of(stage['$prefix$column']),
  };
}
