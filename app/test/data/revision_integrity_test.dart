import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/revision_digest.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

/// 方案 3.5、ADR-0054 与审查 S1 的数据层验收：一致性摘要、分表摘要与完整性。
///
/// 摘要要求“增量更新”和“整库重算”得到同一个值，分表值之和恒等于总摘要，所以
/// 每次写入之后都把 `HEAD` 记录的 `state_digest` 与按当前表重算的值比一次；
/// 完整性检查改为从最近的检查点把变更明细重放到 `HEAD`，重放结果的摘要、`HEAD`
/// 记录的摘要与按当前表重算的摘要三者一致才算通过。提交不再有哈希链。

Map<String, Object?> _memoryRow(String id, String content) => {
  'id': id,
  'kind': 'episodic',
  'content': content,
  'source_kind': 'user',
  'status': 'active',
  'created_at': '2026-11-10 09:00:00',
  'updated_at': '2026-11-10 09:00:00',
};

RevisionChange _remoteInsert(String id, String content) => RevisionChange(
  commitId: 0,
  seq: 1,
  table: 'memory',
  rowKey: id,
  op: ChangeOp.insert,
  after: {
    for (final entry in _memoryRow(id, content).entries)
      if (entry.value != null) entry.key: RevisionValue.of(entry.value),
  },
);

Future<void> _insertMemory(TestRig rig, String id, String content) =>
    rig.db.command(
      (txn) => insertRow(txn, 'memory', _memoryRow(id, content)),
      label: '新增记忆',
    );

Future<List<int>> _commitIds(TestRig rig) async => [
  for (final row in await selectRows(rig.raw, 'revision_commit', orderBy: 'id'))
    row['id']! as int,
];

Future<void> _expectDigestMatchesHead(TestRig rig, {String? reason}) async {
  final head = await rig.engine.commitById(
    rig.raw,
    await rig.engine.headId(rig.raw),
  );
  expect(
    head?.stateDigest,
    await rig.engine.currentStateDigest(rig.raw),
    reason: reason,
  );
}

void main() {
  group('一致性摘要（3.5）', () {
    test('每次写入之后增量摘要与整库重算一致', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _expectDigestMatchesHead(rig, reason: '空库');
      await _insertMemory(rig, 'm1', '一');
      await _expectDigestMatchesHead(rig, reason: '新增');
      await rig.db.command(
        (txn) => updateRow(
          txn,
          'memory',
          {'content': '二'},
          where: 'id = ?',
          whereArgs: ['m1'],
        ),
        label: '修改记忆',
      );
      await _expectDigestMatchesHead(rig, reason: '修改');
      await rig.db.command(
        (txn) => deleteRows(txn, 'memory', where: 'id = ?', whereArgs: ['m1']),
        label: '删除记忆',
      );
      await _expectDigestMatchesHead(rig, reason: '删除');
    });

    test('分表摘要之和等于总摘要，没有行的表写零', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '一');
      final digests = await rig.engine.tableDigests(rig.raw);
      expect(digests.keys.toSet(), versionedTableNames.toSet());
      final head = await rig.engine.commitById(
        rig.raw,
        await rig.engine.headId(rig.raw),
      );
      expect(
        revisionTableDigestsMatch(digests, head!.stateDigest),
        isTrue,
        reason: '各表值之和必须等于这条提交的摘要',
      );
      expect(
        digests['conversation'],
        revisionEmptyStateDigest,
        reason: '没有行的表写 64 个 0',
      );
      expect(
        digests,
        revisionTableDigests(await rig.engine.readProjection(rig.raw)),
        reason: '分表值与按当前表重算的结果逐表相同',
      );
    });

    test('采集增量按表累加，与整库重算逐表一致', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      final before = await rig.engine.readProjection(rig.raw);
      await rig.db.command((txn) async {
        await insertRow(txn, 'memory', _memoryRow('m1', '改之前'));
      }, label: '写入');
      await rig.db.command((txn) async {
        await updateRow(
          txn,
          'memory',
          {'content': '改之后'},
          where: 'id = ?',
          whereArgs: ['m1'],
        );
        await deleteRows(txn, 'memory', where: 'id = ?', whereArgs: ['m1']);
        await insertRow(txn, 'memory', _memoryRow('m3', '新'));
      }, label: '改写');
      final after = await rig.engine.readProjection(rig.raw);
      final fromScratch = revisionTableDigests(after);
      expect((before['memory'] ?? {}).isEmpty, isTrue);
      expect(fromScratch['memory'], isNot(revisionEmptyStateDigest));
      expect(
        await rig.engine.tableDigests(rig.raw),
        fromScratch,
        reason: '增量更新与整库重算必须得到同一组分表值',
      );
    });

    test('远端提交的应用也保持分表之和等于总摘要', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await rig.revisions.applyRemoteCommit(
        uid: 'remote-1',
        action: '另一台设备新增记忆',
        actor: 'user',
        changes: [_remoteInsert('m9', '远端写下的')],
        originDevice: 'device-b',
        authoredAt: DateTime(2026, 11, 11, 8),
        serverSeq: 7,
      );
      final head = await rig.engine.commitById(
        rig.raw,
        await rig.engine.headId(rig.raw),
      );
      expect(head?.serverSeq, 7, reason: '远端提交记下服务端序号');
      expect(head?.originDevice, 'device-b');
      expect(
        revisionTableDigestsMatch(
          await rig.engine.tableDigests(rig.raw),
          head!.stateDigest,
        ),
        isTrue,
      );
    });
  });

  group('完整性（ADR-0054 与审查 S1）', () {
    test('正常历史可以重放并核对两份摘要', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      for (var index = 1; index <= 3; index++) {
        await _insertMemory(rig, 'm$index', '记忆 $index');
      }
      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
      expect(report.isClean, isTrue);
      expect(report.checkedCommits, 4, reason: '初始基线加三条写入');
      expect(report.commitId, await rig.engine.headId(rig.raw));
      final commits = await rig.engine.commits(rig.raw);
      expect(
        [for (final commit in commits.reversed) commit.changeCount],
        [0, 1, 1, 1],
        reason: '变更条数在读取时现数',
      );
    });

    test('篡改变更明细之后重放得到的摘要对不上', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '原始内容');
      final head = await rig.engine.headId(rig.raw);

      final change = (await selectRows(
        rig.raw,
        'revision_change',
        where: 'commit_id = ?',
        whereArgs: [head],
      )).first;
      await rig.raw.execute(
        'UPDATE revision_change SET after_json = ? '
        'WHERE commit_id = ? AND seq = ?',
        [
          jsonEncode({
            'content': {'t': 'text', 'v': '被篡改'},
          }),
          head,
          change['seq'],
        ],
      );

      final report = await rig.revisions.verifyIntegrity();
      expect(report.isClean, isFalse);
      expect(
        report.problems.any((problem) => problem.contains('重放结果')),
        isTrue,
        reason: report.summary,
      );
    });

    test('绕过命令事务直接写业务行，摘要比对失败', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '正常写入');

      // 直接写库：没有命令事务，触发器不采集，也不形成提交。
      await insertRow(rig.raw, 'memory', _memoryRow('m2', '绕过命令'));

      final report = await rig.revisions.verifyIntegrity();
      expect(report.isClean, isFalse);
      expect(
        report.problems.any((problem) => problem.contains('当前数据')),
        isTrue,
        reason: report.summary,
      );
    });

    test('篡改 HEAD 提交的摘要能发现，篡改其中的提交身份不会误报', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '内容');
      final head = await rig.engine.headId(rig.raw);

      // 提交身份不再参与完整性：只改 uid 不影响重放与摘要。
      await rig.raw.execute(
        "UPDATE revision_commit SET uid = 'tampered-uid' WHERE id = ?",
        [head],
      );
      expect((await rig.revisions.verifyIntegrity()).isClean, isTrue);

      // 改动这条提交记录的摘要：重放结果与它、当前数据与它都会对不上。
      await rig.raw.execute(
        'UPDATE revision_commit SET state_digest = ? WHERE id = ?',
        [revisionEmptyStateDigest, head],
      );
      final report = await rig.revisions.verifyIntegrity();
      expect(
        report.problems.any((problem) => problem.contains('重放结果')),
        isTrue,
        reason: report.summary,
      );
    });

    test('裁剪之后仍能从未被删的检查点重放到 HEAD', () async {
      final clock = MutableTestClock(DateTime(2026, 1, 1, 9));
      final rig = await openTestRig(engine: RevisionEngine(clock: clock.call));
      addTearDown(rig.close);
      for (var index = 1; index <= 5; index++) {
        clock.advance(const Duration(days: 1));
        await _insertMemory(rig, 'm$index', '记忆 $index');
      }

      await rig.engine.prune(rig.raw, retentionDays: 0, maxBytes: 1);

      final kept = await _commitIds(rig);
      expect(kept.length, lessThan(6), reason: '预算为 1 字节时应当删掉一些提交');
      expect(kept.first, greaterThan(0), reason: '最早保留的提交之前有被删掉的提交');
      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
      await _expectDigestMatchesHead(rig, reason: '裁剪之后');
    });

    test('清理本机历史之后只剩一条基线，重放与摘要一致', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '一');
      await _insertMemory(rig, 'm2', '二');

      await rig.engine.clearHistory(rig.raw);

      final kept = await _commitIds(rig);
      expect(kept, hasLength(1));
      final commit = await rig.engine.commitById(rig.raw, kept.single);
      expect(commit?.kind, RevisionKind.baseline);
      expect(commit?.parentId, isNull);
      await _expectDigestMatchesHead(rig, reason: '清理本机历史之后');
      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
      expect(report.checkedCommits, 1);
      expect(
        await selectRows(rig.raw, 'revision_ref'),
        isEmpty,
        reason: '清理本机历史会删掉全部命名版本，不留墓碑',
      );
    });
  });

  group('检查点摘要（3.5）', () {
    test('检查点记录投影摘要，重建时与投影比对', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '一');
      final head = await rig.engine.headId(rig.raw);

      await rig.engine.materializeCheckpoint(rig.raw, head, kind: 'named');
      final checkpoint = (await rig.engine.checkpoints(rig.raw)).first;
      expect(checkpoint.commitId, head);
      expect(
        checkpoint.stateDigest,
        await rig.engine.currentStateDigest(rig.raw),
      );

      // 检查点记录的摘要被改坏：重建不再把它当成起点。
      await rig.raw.execute(
        'UPDATE revision_checkpoint SET state_digest = ? WHERE id = ?',
        [revisionEmptyStateDigest, checkpoint.id],
      );
      await expectLater(
        rig.engine.projectionAt(rig.raw, head),
        throwsA(isA<RevisionCorruption>()),
      );
    });

    test('检查点的附件清单只存在引用表里', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      final columns = await rig.raw.rawQuery(
        'PRAGMA table_info("revision_checkpoint")',
      );
      final names = {for (final row in columns) row['name'] as String};
      expect(names, isNot(contains('asset_hashes_json')));
      expect(names, isNot(contains('checksum')));
      expect(names, contains('state_digest'));
    });
  });
}
