import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

/// 方案 3.9 的验收：增量恢复按净变化反向写入，与整库替换得到同样的业务表，
/// 只差一行的恢复不改其他行的 `rowid`；起点被裁掉时退回整库替换；预览与恢复
/// 用同一份反向变化。
///
/// 两条路径的结果在同一个用例里对照：两份库回放同一段随机历史，一份保留完整
/// 明细走增量，另一份删掉一条提交的明细迫使整库替换，恢复之后逐表比较。
RevisionEngine _engine({DateTime Function() clock = _fixedClock}) =>
    RevisionEngine(clock: clock);

DateTime _fixedClock() => DateTime(2026, 11, 10, 9);

Future<void> _insertMemory(WriteTransaction txn, String id, String content) =>
    insertRow(txn.executor, 'memory', {
      'id': id,
      'kind': 'preference',
      'content': content,
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });

Future<void> _insertGoal(WriteTransaction txn, String id, String title) =>
    insertRow(txn.executor, 'learning_goal', {
      'id': id,
      'title': title,
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });

Future<void> _renameMemory(WriteTransaction txn, String id, String content) =>
    updateRow(
      txn.executor,
      'memory',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );

/// 回放同一段随机历史：随机种子固定，两份库的提交与业务行因此一一对应。
Future<List<int>> _randomHistory(TestRig rig) async {
  final writes = WriteTransactions(rig.db, revisions: rig.engine);
  final random = Random(20261121);
  final memories = <String>[];
  final goals = <String>[];
  final deleted = <String>[];
  final points = <int>[await rig.engine.headId(rig.raw)];

  for (var step = 0; step < 200; step++) {
    final choice = random.nextInt(100);
    await writes.run((txn) async {
      if (choice < 30 || (memories.isEmpty && goals.isEmpty)) {
        final id = 'memory-$step';
        await _insertMemory(
          txn,
          id,
          '第 $step 条${'内容' * (1 + random.nextInt(3))}',
        );
        memories.add(id);
      } else if (choice < 50) {
        final id = 'goal-$step';
        await _insertGoal(txn, id, '目标 $step');
        goals.add(id);
      } else if (choice < 70 && memories.isNotEmpty) {
        final id = memories[random.nextInt(memories.length)];
        await updateRow(
          txn.executor,
          'memory',
          {
            'content': '改写 $step',
            'status': random.nextBool() ? 'active' : 'superseded',
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      } else if (choice < 82 && goals.isNotEmpty) {
        final id = goals[random.nextInt(goals.length)];
        await updateRow(
          txn.executor,
          'learning_goal',
          {
            'title': '改过的目标 $step',
            'scope_text': random.nextBool() ? null : '范围 $step',
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      } else if (choice < 92) {
        if (memories.isNotEmpty) {
          final id = memories.removeAt(random.nextInt(memories.length));
          await deleteRows(
            txn.executor,
            'memory',
            where: 'id = ?',
            whereArgs: [id],
          );
          deleted.add(id);
        } else if (goals.isNotEmpty) {
          final id = goals.removeAt(random.nextInt(goals.length));
          await deleteRows(
            txn.executor,
            'learning_goal',
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      } else if (deleted.isNotEmpty) {
        // 删掉之后又用同一个主键写回来：净变化可能是新增，也可能是修改。
        final id = deleted.removeAt(random.nextInt(deleted.length));
        await _insertMemory(txn, id, '恢复 $step');
        memories.add(id);
      }
    }, label: '随机写入 $step');
    points.add(await rig.engine.headId(rig.raw));
  }
  return points;
}

/// 两张业务表的 `rowid` 与主键，按主键排序；用来核对增量恢复没有动其他行。
Future<List<String>> _rowIds(TestRig rig, List<String> tables) async {
  final result = <String>[];
  for (final table in tables) {
    final rows = await rig.raw.rawQuery(
      'SELECT rowid AS row_id, id FROM "$table" ORDER BY id',
    );
    for (final row in rows) {
      result.add('$table|${row['id']}|${row['row_id']}');
    }
  }
  return result;
}

String _describeRow(TypedRow? row) {
  // 忘了的一侧在内存里是 null，从库里读回来是空映射，两者按同一种写法比较。
  if (row == null || row.isEmpty) return '-';
  final columns = row.keys.toList()..sort();
  return columns.map((column) => '$column=${row[column]}').join(';');
}

String _describeChange(RevisionChange change) =>
    '${change.table}|${change.rowKey}|${change.op.value}'
    '|${_describeRow(change.before)}|${_describeRow(change.after)}';

List<String> _describeChanges(Iterable<RevisionChange> changes) =>
    [for (final change in changes) _describeChange(change)]..sort();

String _describeEntry(RevisionDiffEntry entry) =>
    '${entry.table}|${entry.rowKey}|${entry.op.value}'
    '|${(entry.columns.toList()..sort()).join(',')}';

List<String> _describeEntries(Iterable<RevisionDiffEntry> entries) =>
    [for (final entry in entries) _describeEntry(entry)]..sort();

List<String> _entriesFromChanges(Iterable<RevisionChange> changes) => [
  for (final change in changes)
    _describeEntry(
      RevisionDiffEntry(
        table: change.table,
        rowKey: change.rowKey,
        op: change.op,
        columns: change.op == ChangeOp.update
            ? change.after!.keys.toSet()
            : const <String>{},
      ),
    ),
]..sort();

void main() {
  test('200 次随机写入之后任取目标提交，增量恢复与整库替换业务表一致', () async {
    // 两份库回放同一段历史：A 保留完整明细，恢复走增量；B 删掉原 HEAD 那条
    // 提交的变更明细，折叠不出净变化，跨过它的恢复只能退回整库替换。
    final incremental = await openTestRig(engine: _engine());
    final replaced = await openTestRig(engine: _engine());
    addTearDown(incremental.close);
    addTearDown(replaced.close);

    final points = await _randomHistory(incremental);
    final replacedPoints = await _randomHistory(replaced);
    expect(replacedPoints, points, reason: '两份库回放同一段历史');
    expect(points, hasLength(201));

    final originalHead = points.last;
    await deleteRows(
      replaced.raw,
      'revision_change',
      where: 'commit_id = ?',
      whereArgs: [originalHead],
    );

    final targets = <int>[points[20], points[120], points[190]];
    for (final target in targets) {
      final targetProjection = await incremental.engine.projectionAt(
        incremental.raw,
        target,
      );

      // A 走增量：目标在保留历史内、明细完整。
      await incremental.engine.restore(
        incremental.raw,
        target,
        expectedHead: await incremental.engine.headId(incremental.raw),
      );
      final incrementalProjection = await incremental.engine.readProjection(
        incremental.raw,
      );
      expect(
        incrementalProjection,
        targetProjection,
        reason: '增量恢复应当得到提交 $target 的业务表',
      );

      // B 走整库替换：原 HEAD 的明细不完整，跨过它的折叠不可用。
      final replacedHead = await replaced.engine.headId(replaced.raw);
      await expectLater(
        replaced.engine.foldChanges(replaced.raw, target, replacedHead),
        throwsA(anything),
        reason: '提交 $originalHead 的明细被删掉之后不能按明细合并',
      );
      await replaced.engine.restore(
        replaced.raw,
        target,
        expectedHead: replacedHead,
      );
      expect(
        await replaced.engine.readProjection(replaced.raw),
        incrementalProjection,
        reason: '两条路径恢复到提交 $target 之后业务表应当完全相同',
      );

      // 回到原 HEAD 的状态，下一个目标从同一份数据出发。
      await incremental.engine.restore(
        incremental.raw,
        originalHead,
        expectedHead: await incremental.engine.headId(incremental.raw),
      );
      await replaced.engine.restore(
        replaced.raw,
        originalHead,
        expectedHead: await replaced.engine.headId(replaced.raw),
      );
    }
  });

  test('只差一行的恢复不改其他行的 rowid，恢复提交带目标摘要', () async {
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);

    for (var index = 0; index < 5; index++) {
      await writes.run(
        (txn) => _insertMemory(txn, 'memory-$index', '第 $index 条'),
        label: '写入记忆',
      );
    }
    // 中间删掉两行，留下不连续的 rowid：整库替换会按创建顺序重新插入，rowid
    // 因此变得连续；增量恢复不删没改到的行，rowid 保持原样。
    for (final id in ['memory-1', 'memory-3']) {
      await writes.run(
        (txn) => deleteRows(
          txn.executor,
          'memory',
          where: 'id = ?',
          whereArgs: [id],
        ),
        label: '删除记忆',
      );
    }
    await writes.run((txn) => _insertGoal(txn, 'goal-1', '目标'), label: '写入目标');
    final target = await rig.engine.headId(rig.raw);
    final targetCommit = await rig.engine.commitById(rig.raw, target);
    final rowIdsBefore = await _rowIds(rig, ['memory', 'learning_goal']);
    expect(
      rowIdsBefore
          .where((entry) => entry.startsWith('memory|'))
          .map((entry) => entry.split('|').last)
          .toList(),
      hasLength(3),
      reason: '留下三行记忆',
    );
    final projectionBefore = await rig.engine.readProjection(rig.raw);

    await writes.run(
      (txn) => _renameMemory(txn, 'memory-2', '只改这一条'),
      label: '修改一条记忆',
    );
    final head = await rig.engine.headId(rig.raw);

    final restored = await rig.engine.restore(
      rig.raw,
      target,
      expectedHead: head,
    );
    expect(restored.kind, RevisionKind.restore);
    expect(restored.restoredCommitId, target);
    expect(restored.changeCount, 1, reason: '只改了一条记忆，恢复提交也只记这一行');
    expect(
      restored.stateDigest,
      targetCommit!.stateDigest,
      reason: '恢复提交的摘要等于目标投影的整库摘要（方案 3.5）',
    );
    expect(
      await _rowIds(rig, ['memory', 'learning_goal']),
      rowIdsBefore,
      reason: '只写回被改到的那一行，其他行的 rowid 不动',
    );
    expect(await rig.engine.readProjection(rig.raw), projectionBefore);
    expect(
      (await selectRows(
        rig.raw,
        'memory',
        where: 'id = ?',
        whereArgs: ['memory-2'],
      )).single['content'],
      '第 2 条',
    );
  });

  test('起点已被裁掉时恢复退回整库替换，结果与目标投影一致', () async {
    final clock = MutableTestClock(DateTime(2026, 11, 10, 9));
    final rig = await openTestRig(engine: _engine(clock: clock.call));
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    for (var index = 0; index < 8; index++) {
      // 每条提交隔 7 天：最近 14 天里只剩最后三条，起点是裁剪留下的断点。
      clock.advance(const Duration(days: 7));
      await writes.run(
        (txn) => _insertMemory(txn, 'memory-$index', '第 $index 条'),
        label: '写入记忆',
      );
    }

    final pruned = await rig.revisions.prune(retentionDays: 14, maxBytes: 1);
    expect(pruned.removedCommits, greaterThan(0));
    final ids = (await rig.engine.commits(
      rig.raw,
    )).map((commit) => commit.id).toList()..sort();
    final target = ids.first;
    expect(target, greaterThan(0), reason: '初始提交与更早的提交已经被裁掉');
    final oldestCommit = await rig.engine.commitById(rig.raw, target);
    expect(oldestCommit!.parentId, isNull, reason: '裁剪把起点的父提交断开了');
    final targetProjection = await rig.engine.projectionAt(rig.raw, target);
    final head = await rig.engine.headId(rig.raw);

    // 起点是裁剪留下的断点，只按明细合并拿不到可信结果，恢复因此整库替换。
    await expectLater(
      rig.engine.foldChanges(rig.raw, target, head),
      throwsA(anything),
    );
    final before = await rig.engine.readProjection(rig.raw);
    final preview = await rig.engine.previewRestore(rig.raw, target);
    expect(preview.head, head);
    final restored = await rig.engine.restore(
      rig.raw,
      target,
      expectedHead: head,
    );
    final after = await rig.engine.readProjection(rig.raw);
    expect(after, targetProjection, reason: '整库替换之后等于目标投影');
    final expectedChanges = diffProjections(before, after);
    expect(restored.changeCount, expectedChanges.length);
    expect(preview.diff.entries.length, expectedChanges.length);
    expect(
      _describeChanges(await rig.engine.changesFor(rig.raw, restored.id)),
      _describeChanges(expectedChanges),
      reason: '整库替换的变更明细仍然由两份投影比较得出',
    );
  });

  test('预览的差异与实际恢复的结果一致', () async {
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);

    for (var index = 0; index < 3; index++) {
      await writes.run(
        (txn) => _insertMemory(txn, 'memory-$index', '第 $index 条'),
        label: '写入记忆',
      );
    }
    await writes.run((txn) => _insertGoal(txn, 'goal-1', '目标'), label: '写入目标');
    final target = await rig.engine.headId(rig.raw);

    // 目标之后既有修改、删除，也有新增，预览应当逐条对上。
    await writes.run(
      (txn) => _renameMemory(txn, 'memory-1', '目标之后改过'),
      label: '修改记忆',
    );
    await writes.run(
      (txn) => deleteRows(
        txn.executor,
        'memory',
        where: 'id = ?',
        whereArgs: ['memory-2'],
      ),
      label: '删除记忆',
    );
    await writes.run(
      (txn) => _insertMemory(txn, 'memory-after', '目标之后新增'),
      label: '新增记忆',
    );
    final head = await rig.engine.headId(rig.raw);

    final before = await rig.engine.readProjection(rig.raw);
    final preview = await rig.engine.previewRestore(rig.raw, target);
    expect(preview.target.id, target);
    expect(preview.head, head);
    final expectedChanges = diffProjections(
      before,
      await rig.engine.projectionAt(rig.raw, target),
    );
    expect(
      _describeEntries(preview.diff.entries),
      _entriesFromChanges(expectedChanges),
      reason: '预览按净变化给出要写回的行与列',
    );
    expect(preview.diff.insertCount, 1);
    expect(preview.diff.updateCount, 1);
    expect(preview.diff.deleteCount, 1);

    final restored = await rig.engine.restore(
      rig.raw,
      target,
      expectedHead: head,
    );
    final after = await rig.engine.readProjection(rig.raw);
    final actualChanges = diffProjections(before, after);
    expect(
      _describeChanges(await rig.engine.changesFor(rig.raw, restored.id)),
      _describeChanges(actualChanges),
      reason: '恢复提交的变更明细就是预览里的那份反向变化',
    );
    expect(
      _describeEntries(preview.diff.entries),
      _entriesFromChanges(actualChanges),
      reason: '预览与实际恢复的结果一致',
    );
  });
}
