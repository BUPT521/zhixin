import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/drift/app_database.dart';
import 'package:zhixin/data/db/drift/drift_raw.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';

import '../support/test_db.dart';

/// 修一条目标的标题，用于“写成与现值相同”的用例。
Future<void> _renameGoal(RawExecutor executor, String id, String title) =>
    updateRow(
      executor,
      'learning_goal',
      {'title': title},
      where: 'id = ?',
      whereArgs: [id],
    );

Future<void> _insertGoal(
  RawExecutor executor,
  String id, {
  String title = '线性代数',
}) => insertRow(executor, 'learning_goal', {
  'id': id,
  'title': title,
  'status': 'active',
  'created_at': '2026-11-20T10:00:00',
  'updated_at': '2026-11-20T10:00:00',
});

/// 库里下一个可分配的提交编号；没有净变化的写入不应推动它。
Future<int> _nextCommit(RawExecutor executor) async =>
    (await selectRows(
          executor,
          'revision_sequence',
          columns: ['next_commit'],
        )).single['next_commit']!
        as int;

Future<List<int>> _commitIds(RawExecutor executor) async => [
  for (final row in await selectRows(
    executor,
    'revision_commit',
    columns: ['id'],
    where: 'id > 0',
    orderBy: 'id',
  ))
    row['id']! as int,
];

void main() {
  test('写成与现值相同不形成提交，结果按跳过返回，序号不前进', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final transactions = WriteTransactions(rig.db, revisions: rig.engine);

    await rig.db.command(
      (txn) => _insertGoal(txn, 'goal-1', title: '线性代数'),
      label: '新建目标',
    );
    final head = await rig.engine.headId(rig.raw);
    final sequence = await _nextCommit(rig.raw);

    final result = await transactions.run((txn) async {
      await _renameGoal(txn.executor, 'goal-1', '线性代数');
      return txn.result();
    }, label: '修改目标');

    expect(result.changed, isFalse, reason: '值没有变化，没有形成提交');
    expect(result.commitId, isNull);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await _nextCommit(rig.raw), sequence, reason: '没有预留编号，序号不动');
    // 暂存表在事务之外总是空的，触发器只按 capturing 采集。
    final staged = await rig.raw.rawQuery(
      'SELECT COUNT(*) AS count FROM "rev_stage_learning_goal"',
    );
    expect(staged.single['count'], 0);
  });

  test('只读的 transaction() 不消耗提交编号', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await _insertGoal(rig.db, 'goal-1');
    final head = await rig.engine.headId(rig.raw);
    final sequence = await _nextCommit(rig.raw);

    final rows = await rig.db.transaction(
      (txn) => txn.rawQuery('SELECT id FROM "learning_goal"'),
    );

    expect(rows, isNotEmpty);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await _nextCommit(rig.raw), sequence);
    expect(await _commitIds(rig.raw), [head]);
  });

  test('连续写入的提交编号连续', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final transactions = WriteTransactions(rig.db, revisions: rig.engine);

    for (var index = 0; index < 5; index++) {
      final result = await transactions.run((txn) async {
        await _insertGoal(txn.executor, 'goal-$index', title: '目标 $index');
        return txn.result();
      }, label: '新建目标');
      expect(result.changed, isTrue);
      expect(result.commitId, index + 1);
    }

    expect(await _commitIds(rig.raw), [1, 2, 3, 4, 5]);
    expect(await _nextCommit(rig.raw), 6);
  });

  test('生成回执时预留的编号就是落库的提交编号', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final transactions = WriteTransactions(rig.db, revisions: rig.engine);

    int? reserved;
    final result = await transactions.run((txn) async {
      reserved = await txn.requireCommitId();
      await _insertGoal(txn.executor, 'goal-1');
      return txn.result();
    }, label: '新建目标');

    expect(reserved, isNotNull);
    expect(result.changed, isTrue);
    expect(result.commitId, reserved);
    expect(await rig.engine.headId(rig.raw), reserved);
    final commit = await rig.engine.commitById(rig.raw, result.commitId!);
    expect(commit, isNotNull);
    final changes = await rig.engine.changesFor(rig.raw, result.commitId!);
    expect(changes.map((change) => change.commitId), everyElement(reserved));
  });

  test('显式要了回执编号但没有净变化时占号但不形成提交', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final transactions = WriteTransactions(rig.db, revisions: rig.engine);
    final head = await rig.engine.headId(rig.raw);
    final sequence = await _nextCommit(rig.raw);

    final result = await transactions.run((txn) async {
      await txn.requireCommitId();
      return txn.result();
    }, label: '只生成回执');

    expect(result.changed, isFalse, reason: '没有净变化，结果按跳过返回');
    expect(result.commitId, isNull);
    expect(await rig.engine.headId(rig.raw), head);
    expect(await _nextCommit(rig.raw), sequence + 1, reason: '预留过的编号不回退');
    expect(await rig.engine.commitById(rig.raw, sequence), isNull);
  });

  test('打开库时保留库里原有的非采集触发器，暂存表不再有 commit_id', () async {
    final app = AppDatabase.memory();
    addTearDown(app.close);
    final raw = DriftRawDatabase(app);
    await raw.execute(
      'CREATE TRIGGER "custom_marker" AFTER INSERT ON "learning_goal" '
      'BEGIN SELECT 1; END',
    );

    final engine = RevisionEngine();
    await engine.initialize(raw);
    // 再打开一次模拟重新启动：采集对象重建，其他模块的触发器仍在。
    await engine.initialize(raw);

    final triggers = await raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    );
    final names = {for (final row in triggers) row['name']! as String};
    expect(names, contains('custom_marker'));
    expect(names, contains('rev_capture_learning_goal_insert'));

    final columns = await raw.rawQuery(
      'PRAGMA table_info("rev_stage_learning_goal")',
    );
    final columnNames = {for (final row in columns) row['name']! as String};
    expect(columnNames, isNot(contains('commit_id')));
    expect(columnNames, containsAll({'seq', 'row_key', 'op'}));
    expect(columnNames, containsAll({'o_title', 'n_title'}));
  });
}
