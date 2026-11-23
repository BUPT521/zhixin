part of 'revision_engine.dart';

/// 采集侧：安装暂存表与触发器，读取暂存行并合并成一次提交的净变化。
///
/// 拥有者：泳道 A（ADR-0039 第 3.3 节）。私有成员与同库其他文件共享。

/// 创建采集暂存表、触发器和版本状态行；打开库时执行，重复执行保持幂等。
///
/// 只重建本引擎的采集对象：`rev_capture_` 前缀之外的触发器（其他模块建的）
/// 原样保留；暂存表按当前列重建，列变了也能跟上（R12）。暂存表只在一个写
/// 事务里使用，事务之外总是空的，所以打开库时直接删除重建不会丢数据。
///
/// 版本状态行（`revision_state`）在这里创建，早于编号为 0 的基线提交，所以
/// `head_commit_id` 默认的 0 正好指向基线，不加外键（ADR-0054 决定第 4 条）。
Future<void> installRevisionSchema(
  RawDatabase db,
  RevisionEngine engine,
) async {
  final schema = await engine.tables(db);
  final existing = await selectRows(
    db,
    'sqlite_master',
    columns: ['name'],
    where: "type = 'trigger' AND name GLOB 'rev_capture_*'",
  );
  for (final row in existing) {
    await db.execute('DROP TRIGGER IF EXISTS "${row['name']}"');
  }
  for (final table in schema.values) {
    final stage = table.stageTable;
    final columns = <String>[
      'seq INTEGER PRIMARY KEY AUTOINCREMENT',
      'row_key TEXT NOT NULL',
      'op TEXT NOT NULL',
      for (final column in table.columns) ...[
        _quote('o_$column'),
        _quote('n_$column'),
      ],
    ];
    await db.execute('DROP TABLE IF EXISTS "$stage"');
    await db.execute('CREATE TABLE "$stage" (${columns.join(', ')})');
    await _createTriggers(db, table);
  }

  await insertRow(db, 'revision_state', {
    'id': 1,
    'active_commit': null,
    'capturing': 0,
    'suppress': 0,
    'next_commit': 1,
    'head_commit_id': 0,
    'table_digests_json': jsonEncode(revisionEmptyTableDigests()),
  }, ignore: true);
}

Future<void> _createTriggers(RawDatabase db, RevisionTable table) async {
  final q = _quote;
  final stage = q(table.stageTable);
  final source = q(table.name);
  final when =
      '(SELECT capturing FROM revision_state WHERE id = 1) = 1 '
      'AND (SELECT suppress FROM revision_state WHERE id = 1) = 0';
  final allOld = table.columns.map((c) => q('o_$c')).join(', ');
  final allNew = table.columns.map((c) => q('n_$c')).join(', ');
  final oldValues = table.columns.map((c) => 'OLD.${q(c)}').join(', ');
  final newValues = table.columns.map((c) => 'NEW.${q(c)}').join(', ');
  final key = 'CAST(NEW.${q(table.primaryKey)} AS TEXT)';
  final oldKey = 'CAST(OLD.${q(table.primaryKey)} AS TEXT)';

  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_insert" AFTER INSERT ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (row_key, op, $allOld, $allNew) '
    'VALUES ($key, \'insert\', '
    '${List.filled(table.columns.length, 'NULL').join(', ')}, '
    '$newValues); END',
  );
  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_update" AFTER UPDATE ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (row_key, op, $allOld, $allNew) '
    'VALUES ($key, \'update\', $oldValues, $newValues); END',
  );
  await db.execute(
    'CREATE TRIGGER "rev_capture_${table.name}_delete" AFTER DELETE ON $source '
    'WHEN $when BEGIN '
    'INSERT INTO $stage (row_key, op, $allOld, $allNew) '
    'VALUES ($oldKey, \'delete\', $oldValues, '
    '${List.filled(table.columns.length, 'NULL').join(', ')}); END',
  );
}

mixin RevisionCaptureMixin {
  /// 引擎本身；字段与同库其他文件的方法都经它访问。
  RevisionEngine get self;

  /// 清空整张暂存表：同一时间只有一个写事务，事务之外的暂存表总是空的。
  Future<void> _clearStage(RawExecutor txn) async {
    final schema = await self.tables(txn);
    for (final table in schema.values) {
      await deleteRows(txn, table.stageTable);
    }
  }

  /// 把整张暂存表按“表名＋主键”合并成净变化：插入记修改后整行，删除记删除前
  /// 整行，修改只记变化列；同一次命令里先插入再删除的行不产生变化。
  ///
  /// 合并发生在确定提交编号之前，明细里的 `commitId` 先写 0，由调用方在编号
  /// 定下来之后补上；没有净变化时就不必占一个编号（R1）。
  ///
  /// 同一次合并按“减去旧行哈希、加上新行哈希”算出这次命令对一致性摘要的增量，
  /// 按表分别累加，不再额外读业务表：暂存表两侧本来就是整行，行哈希因此与整库
  /// 重算完全一致（方案 3.5、ADR-0054 决定第 1 条）。
  Future<CapturedChanges> _collect(RawExecutor txn) async {
    final schema = await self.tables(txn);
    final result = <RevisionChange>[];
    final tableDeltas = <String, BigInt>{
      for (final name in versionedTableNames) name: BigInt.zero,
    };
    var seq = 1;
    for (final table in schema.values) {
      final rows = await selectRows(txn, table.stageTable, orderBy: 'seq');
      if (rows.isEmpty) continue;
      var delta = BigInt.zero;
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
          final changed = expandedRevisionColumns(
            table.name,
            changedColumns(before, after),
          );
          if (changed.isEmpty) continue;
          // 摘要按整行算，变更明细只留变化列与列组里的同组成员（审查 S18）；
          // 两侧都用暂存表里的整行。
          delta =
              delta -
              revisionRowHashValue(table.name, entry.key, before) +
              revisionRowHashValue(table.name, entry.key, after);
          result.add(
            RevisionChange(
              commitId: 0,
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
        delta = before == null
            ? delta + revisionRowHashValue(table.name, entry.key, after!)
            : delta - revisionRowHashValue(table.name, entry.key, before);
        result.add(
          RevisionChange(
            commitId: 0,
            seq: seq++,
            table: table.name,
            rowKey: entry.key,
            op: before == null ? ChangeOp.insert : ChangeOp.delete,
            before: before,
            after: after,
          ),
        );
      }
      tableDeltas[table.name] = _modDigest(delta);
    }
    return CapturedChanges(changes: result, tableDeltas: tableDeltas);
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

/// 把摘要的增量收进 2^256 的范围：减出来的负数在这里回绕，与整库重算同余。
BigInt _modDigest(BigInt value) => value % revisionDigestModulus;

/// 一次命令合并出来的净变化与它对各表一致性摘要的增量。
///
/// [tableDeltas] 按表给出“提交之后的状态摘要减去提交之前的状态摘要”，按 2^256
/// 取模；[_appendCommit] 把它加到父提交的分表摘要上，得到这条提交之后各表的值，
/// 总摘要仍等于各表值之和（ADR-0054 决定第 1 条）。
class CapturedChanges {
  const CapturedChanges({required this.changes, required this.tableDeltas});

  final List<RevisionChange> changes;
  final Map<String, BigInt> tableDeltas;

  /// 各表增量之和，等于整库摘要的增量。
  BigInt get digestDelta => revisionDigestSum(tableDeltas.values);
}
