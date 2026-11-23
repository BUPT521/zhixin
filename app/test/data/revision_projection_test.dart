import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

/// 固定时钟的引擎；[idleCheckpointBytes] 用来把空闲检查点的阈值调小。
RevisionEngine _engine({
  int idleCheckpointBytes = 8 * 1024 * 1024,
  DateTime Function() clock = _fixedClock,
}) => RevisionEngine(clock: clock, idleCheckpointBytes: idleCheckpointBytes);

DateTime _fixedClock() => DateTime(2026, 11, 10, 9);

Future<void> _insertMemory(WriteTransaction txn, String id, String content) =>
    insertRow(txn.executor, 'memory', {
      'id': id,
      'kind': 'semantic',
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

String _describeRow(TypedRow? row) {
  if (row == null) return '-';
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

/// 从合并结果推出比较结果的描述，用来逐条核对两者一致。
List<String> _entriesFromChanges(Iterable<RevisionChange> changes) => [
  for (final change in changes)
    _describeEntry(
      RevisionDiffEntry(
        table: change.table,
        rowKey: change.rowKey,
        op: change.op,
        columns: change.op == ChangeOp.update
            ? change.before!.keys.toSet()
            : const <String>{},
      ),
    ),
]..sort();

void main() {
  test('连续 100 次写入都不在写事务里生成检查点', () async {
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    expect(await rig.engine.checkpoints(rig.raw), hasLength(1));

    for (var index = 0; index < 100; index++) {
      var inside = -1;
      await writes.run((txn) async {
        inside = (await rig.engine.checkpoints(txn.executor)).length;
        await _insertMemory(txn, 'memory-$index', '第 $index 条记忆');
      }, label: '写入记忆');
      expect(inside, 1, reason: '第 $index 次写入的事务里不生成检查点');
      expect(await rig.engine.checkpoints(rig.raw), hasLength(1));
    }
  });

  test('累计明细字节数超过阈值后空闲时生成一份检查点', () async {
    const threshold = 1000;
    final rig = await openTestRig(
      engine: _engine(idleCheckpointBytes: threshold),
    );
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);

    var triggeredAt = -1;
    for (var index = 0; index < 40; index++) {
      final beforeCount = (await rig.engine.checkpoints(rig.raw)).length;
      var inside = -1;
      await writes.run((txn) async {
        inside = (await rig.engine.checkpoints(txn.executor)).length;
        await _insertMemory(txn, 'memory-$index', 'x' * 200);
      }, label: '写入记忆');
      expect(inside, beforeCount, reason: '写事务里不生成检查点');
      final afterCount = (await rig.engine.checkpoints(rig.raw)).length;
      if (afterCount == beforeCount + 1) {
        triggeredAt = index;
        break;
      }
      expect(afterCount, beforeCount);
    }
    expect(triggeredAt, greaterThanOrEqualTo(0));
    expect(triggeredAt, greaterThan(0), reason: '阈值以内的写入不生成检查点');

    final checkpoints = await rig.engine.checkpoints(rig.raw);
    expect(checkpoints, hasLength(2));
    final periodic = checkpoints.first;
    expect(periodic.kind, 'periodic');
    // 检查点只有一种编码：gzip 压缩的 JSON，压缩之前的字节数记在 raw_bytes。
    expect(periodic.rawBytes, greaterThan(periodic.payload.length));
    final head = await rig.engine.headId(rig.raw);
    expect(periodic.commitId, head);

    final rebuilt = await rig.engine.projectionAt(rig.raw, periodic.commitId);
    final current = await rig.engine.readProjection(rig.raw);
    expect(projectionsEqual(rebuilt, current), isTrue);
    expect(rebuilt['memory'], hasLength(triggeredAt + 1));
  });

  test('检查点篡改 payload 报损坏，换回正确内容可以重建', () async {
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    for (var index = 0; index < 3; index++) {
      await writes.run(
        (txn) => _insertMemory(txn, 'memory-$index', '第 $index 条记忆'),
        label: '写入记忆',
      );
    }
    final head = await rig.engine.headId(rig.raw);
    await rig.engine.materializeCheckpoint(rig.raw, head, kind: 'named');

    final rows = await selectRows(
      rig.raw,
      'revision_checkpoint',
      orderBy: 'commit_id DESC, id DESC',
    );
    final gzipRow = rows.first;
    final checkpointId = gzipRow['id']! as int;
    // 只有一种编码：gzip 压缩的 JSON（ADR-0054 实施前核对删去了 `json`）。
    expect(gzipRow['encoding'], 'json+gzip');
    final gzipPayload = Uint8List.fromList(gzipRow['payload']! as Uint8List);
    final gzipRawBytes = gzipRow['raw_bytes']! as int;
    final gzipProjection = await rig.engine.projectionAt(rig.raw, head);
    expect(utf8.encode(encodeProjection(gzipProjection)).length, gzipRawBytes);

    // 改一个字节：解压或按摘要比对失败都按损坏报告。
    final tampered = Uint8List.fromList(gzipPayload);
    tampered[tampered.length ~/ 2] ^= 0xFF;
    await updateRow(
      rig.raw,
      'revision_checkpoint',
      {'payload': tampered},
      where: 'id = ?',
      whereArgs: [checkpointId],
    );
    await expectLater(
      rig.engine.projectionAt(rig.raw, head),
      throwsA(isA<RevisionCorruption>()),
    );

    // 内容换回来之后重建结果与当前数据一致。
    await updateRow(
      rig.raw,
      'revision_checkpoint',
      {'payload': gzipPayload, 'raw_bytes': gzipRawBytes},
      where: 'id = ?',
      whereArgs: [checkpointId],
    );
    expect(await rig.engine.projectionAt(rig.raw, head), gzipProjection);
  });

  test('随机 200 次写入后任取两个提交点，合并结果与两次重建一致', () async {
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    final random = Random(20261120);
    final memories = <String>[];
    final goals = <String>[];
    final deleted = <String>[];
    final points = <int>{};

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
              'status': random.nextBool() ? 'active' : 'deleted',
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

    final sorted = points.toList()..sort();
    expect(sorted.length, greaterThan(50));
    final pairs = <(int, int)>[];
    void addPair(int left, int right) {
      if (left == right) return;
      pairs.add((left < right ? left : right, left < right ? right : left));
    }

    addPair(sorted.first, sorted.last);
    addPair(sorted[1], sorted.last);
    addPair(sorted[sorted.length ~/ 2], sorted.last);
    addPair(sorted[sorted.length - 5], sorted.last);
    addPair(sorted[1], sorted[sorted.length ~/ 2]);
    for (var index = 0; index < 4; index++) {
      addPair(
        sorted[random.nextInt(sorted.length)],
        sorted[random.nextInt(sorted.length)],
      );
    }

    for (final (from, to) in pairs) {
      final folded = await rig.engine.foldChanges(rig.raw, from, to);
      final before = await rig.engine.projectionAt(rig.raw, from);
      final after = await rig.engine.projectionAt(rig.raw, to);
      final rebuilt = diffProjections(before, after);
      expect(
        _describeChanges(folded),
        _describeChanges(rebuilt),
        reason: 'foldChanges($from, $to)',
      );

      final diff = await rig.engine.compare(rig.raw, from, to);
      expect(
        _describeEntries(diff.entries),
        _entriesFromChanges(rebuilt),
        reason: 'compare($from, $to)',
      );
    }
  });

  test('起点之前的提交被裁掉后 compare 退回两次重建并给出正确结果', () async {
    final clock = MutableTestClock(DateTime(2026, 11, 10, 9));
    final rig = await openTestRig(engine: _engine(clock: clock.call));
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    for (var index = 0; index < 8; index++) {
      // 每条提交隔 7 天：最近 14 天里只剩最后三条，起点是裁剪留下的断点。
      clock.advance(const Duration(days: 7));
      await writes.run(
        (txn) => _insertMemory(txn, 'memory-$index', '第 $index 条记忆'),
        label: '写入记忆',
      );
    }

    final result = await rig.revisions.prune(retentionDays: 14, maxBytes: 1);
    expect(result.removedCommits, greaterThan(0));

    final ids = (await rig.engine.commits(
      rig.raw,
    )).map((commit) => commit.id).toList()..sort();
    final oldest = ids.first;
    expect(oldest, greaterThan(0), reason: '初始提交与更早的提交已被裁掉');
    final oldestCommit = await rig.engine.commitById(rig.raw, oldest);
    expect(oldestCommit!.parentId, isNull, reason: '裁剪把起点的父提交断开了');

    final head = await rig.engine.headId(rig.raw);
    expect(head, greaterThan(oldest));
    final diff = await rig.engine.compare(rig.raw, oldest, head);
    final before = await rig.engine.projectionAt(rig.raw, oldest);
    final after = await rig.engine.readProjection(rig.raw);
    expect(
      _describeEntries(diff.entries),
      _entriesFromChanges(diffProjections(before, after)),
    );
    expect(diff.entries, isNotEmpty);

    // 起点是裁剪留下的断点，只按明细合并拿不到可信结果，compare 才退回重建。
    await expectLater(
      rig.engine.foldChanges(rig.raw, oldest, head),
      throwsA(anything),
    );

    // 断点之后的提交仍能只按明细合并，结果与两次重建一致。
    final next = ids.firstWhere((id) => id > oldest);
    final folded = await rig.engine.foldChanges(rig.raw, next, head);
    final rebuilt = diffProjections(
      await rig.engine.projectionAt(rig.raw, next),
      after,
    );
    expect(_describeChanges(folded), _describeChanges(rebuilt));
  });

  test('保留提交缺少变更明细时 compare 退回两次重建', () async {
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    for (var index = 0; index < 5; index++) {
      await writes.run(
        (txn) => _insertMemory(txn, 'memory-$index', '第 $index 条记忆'),
        label: '写入记忆',
      );
    }

    final ids = (await rig.engine.commits(
      rig.raw,
    )).map((commit) => commit.id).toList()..sort();
    final from = ids.first;
    final head = ids.last;
    // 先固化一份覆盖整个区间的检查点，再删掉中间提交的明细模拟基线跳变。
    await rig.engine.materializeCheckpoint(rig.raw, head, kind: 'named');
    final jumped = ids[1];
    await deleteRows(
      rig.raw,
      'revision_change',
      where: 'commit_id = ?',
      whereArgs: [jumped],
    );

    final diff = await rig.engine.compare(rig.raw, from, head);
    final before = await rig.engine.projectionAt(rig.raw, from);
    final after = await rig.engine.readProjection(rig.raw);
    expect(
      _describeEntries(diff.entries),
      _entriesFromChanges(diffProjections(before, after)),
    );
    expect(diff.entries, isNotEmpty);

    await expectLater(
      rig.engine.foldChanges(rig.raw, from, head),
      throwsA(anything),
    );
  });
  test('随机写入序列上任意两个提交点的 foldChanges 都与两次重建一致', () async {
    // 60 次随机写入、任取两点全组合（1770 对）；每个提交点的投影先算一次，
    // 公共测试的超时放得下，数量再大就只能抽样。
    final rig = await openTestRig(engine: _engine());
    addTearDown(rig.close);
    final writes = WriteTransactions(rig.db, revisions: rig.engine);
    final random = Random(20261121);
    final memories = <String>[];
    final deleted = <String>[];
    final points = <int>[await rig.engine.headId(rig.raw)];

    for (var step = 0; step < 60; step++) {
      final choice = random.nextInt(100);
      await writes.run((txn) async {
        if (choice < 40 || (memories.isEmpty && deleted.isEmpty)) {
          final id = 'memory-$step';
          await _insertMemory(txn, id, '第 $step 条');
          memories.add(id);
        } else if (choice < 70 && memories.isNotEmpty) {
          final id = memories[random.nextInt(memories.length)];
          await updateRow(
            txn.executor,
            'memory',
            {'content': '改写 $step'},
            where: 'id = ?',
            whereArgs: [id],
          );
        } else if (choice < 85 && memories.isNotEmpty) {
          final id = memories.removeAt(random.nextInt(memories.length));
          await deleteRows(
            txn.executor,
            'memory',
            where: 'id = ?',
            whereArgs: [id],
          );
          deleted.add(id);
        } else if (deleted.isNotEmpty) {
          // 删掉之后又用同一个主键写回来：净变化可能是新增，也可能是修改。
          final id = deleted.removeAt(random.nextInt(deleted.length));
          await _insertMemory(txn, id, '恢复 $step');
          memories.add(id);
        }
      }, label: '随机写入 $step');
      points.add(await rig.engine.headId(rig.raw));
    }

    final projections = <int, Projection>{};
    for (final point in points) {
      projections[point] = await rig.engine.projectionAt(rig.raw, point);
    }
    var compared = 0;
    for (var left = 0; left < points.length; left++) {
      for (var right = left + 1; right < points.length; right++) {
        final from = points[left];
        final to = points[right];
        final folded = await rig.engine.foldChanges(rig.raw, from, to);
        final rebuilt = diffProjections(projections[from]!, projections[to]!);
        expect(
          _describeChanges(folded),
          _describeChanges(rebuilt),
          reason: 'foldChanges($from, $to)',
        );
        compared++;
      }
    }
    expect(compared, points.length * (points.length - 1) ~/ 2);
    expect(compared, greaterThan(1500));
  });
}
