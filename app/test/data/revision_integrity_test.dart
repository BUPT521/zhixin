import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/revision_digest.dart';
import 'package:zhixin/data/revisions/revision_engine.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

/// 方案 3.5、3.10、3.12 的数据层验收：一致性摘要、哈希链与作者信息。
///
/// 摘要要求“增量更新”和“整库重算”得到同一个值，所以每次写入之后都把 `HEAD`
/// 记录的 `state_digest` 与按当前表重算的值比一次；哈希链要求在篡改变更明细、
/// 业务行与提交身份时都能发现；作者信息按本机与远端两条规则写入。

Map<String, Object?> _memoryRow(String id, String content) => {
  'id': id,
  'kind': 'preference',
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

Future<void> _renameMemory(TestRig rig, String id, String content) =>
    rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {'content': content, 'updated_at': '2026-11-10 10:00:00'},
        where: 'id = ?',
        whereArgs: [id],
      ),
      label: '修改记忆',
    );

Future<void> _deleteMemory(TestRig rig, String id) => rig.db.command(
  (txn) => deleteRows(txn, 'memory', where: 'id = ?', whereArgs: [id]),
  label: '删除记忆',
);

/// `HEAD` 记录的摘要必须等于按当前表整库重算的摘要。
Future<void> _expectDigestMatchesHead(TestRig rig, {String? reason}) async {
  final head = await rig.engine.headId(rig.raw);
  final commit = await rig.engine.commitById(rig.raw, head);
  final digest = await rig.engine.currentStateDigest(rig.raw);
  expect(commit?.stateDigest, digest, reason: reason ?? '提交 $head 的摘要应当等于整库重算');
}

Future<List<int>> _commitIds(TestRig rig) async {
  final rows = await selectRows(
    rig.raw,
    'revision_commit',
    columns: ['id'],
    orderBy: 'id',
  );
  return [for (final row in rows) row['id']! as int];
}

void main() {
  group('一致性摘要（3.5）', () {
    test('每次写入之后增量摘要都等于整库重算', () async {
      // 撤销要经过应用层注册的业务约束，所以这一条用带撤销规则的装配。
      final rig = await openTestRigWithUndoRules();
      addTearDown(rig.close);

      // 空库只有种子行（profile）：初始基线的摘要就是这份投影的整库重算值。
      final baseline = await rig.engine.commitById(rig.raw, 0);
      expect(
        baseline?.stateDigest,
        await rig.engine.currentStateDigest(rig.raw),
      );
      await _expectDigestMatchesHead(rig, reason: '空库的摘要');

      await _insertMemory(rig, 'm1', '第一条');
      await _expectDigestMatchesHead(rig, reason: '新增之后');

      await _renameMemory(rig, 'm1', '改过的第一条');
      await _expectDigestMatchesHead(rig, reason: '修改之后');

      // 同一个命令里先插入再删除不产生净变化，摘要也不动。
      await rig.db.command((txn) async {
        await insertRow(txn, 'memory', _memoryRow('m2', '转瞬即逝'));
        await deleteRows(txn, 'memory', where: 'id = ?', whereArgs: ['m2']);
      }, label: '插入后删除');
      await _expectDigestMatchesHead(rig, reason: '净变化为零之后');

      // 同一个命令里先删除再插入同一主键，摘要按净结果只算一次替换。
      await rig.db.command((txn) async {
        await deleteRows(txn, 'memory', where: 'id = ?', whereArgs: ['m1']);
        await insertRow(txn, 'memory', _memoryRow('m1', '换了一条'));
      }, label: '删除后重插');
      await _expectDigestMatchesHead(rig, reason: '同一命令里替换整行之后');

      await _deleteMemory(rig, 'm1');
      await _expectDigestMatchesHead(rig, reason: '删除之后');

      // 撤销也走采集路径，摘要照样能对上。
      await _insertMemory(rig, 'm3', '待撤销');
      final undoable = await rig.engine.headId(rig.raw);
      final undo = await rig.revisions.undo.undo(rig.raw, undoable);
      expect(undo.applied, isTrue);
      await _expectDigestMatchesHead(rig, reason: '撤销之后');

      // 整版恢复直接给目标投影的摘要，不再经过暂存表。
      final target = await rig.engine.headId(rig.raw);
      await _insertMemory(rig, 'm4', '恢复前新增');
      final head = await rig.engine.headId(rig.raw);
      await rig.revisions.restore(target, expectedHead: head);
      await _expectDigestMatchesHead(rig, reason: '整版恢复之后');

      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
    });

    test('远端提交写入之后摘要等于整库重算，来源设备与作者时间按远端规则写入', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);

      final applied = await rig.revisions.applyRemoteCommit(
        uid: 'remote-1',
        action: '从其他设备同步',
        actor: 'user',
        changes: [_remoteInsert('r1', '远端的第一条')],
        originDevice: 'device-b',
        authoredAt: DateTime(2026, 1, 1, 8, 30),
      );
      expect(applied.commit, isNotNull);
      await _expectDigestMatchesHead(rig, reason: '应用远端提交之后');

      final commit = applied.commit!;
      expect(commit.kind, RevisionKind.remote);
      expect(commit.originDevice, 'device-b');
      expect(commit.authoredAt, DateTime(2026, 1, 1, 8, 30));
      expect(commit.isRemote, isTrue);
      final rows = await selectRows(
        rig.raw,
        'revision_commit',
        columns: ['authored_at', 'created_at'],
        where: 'id = ?',
        whereArgs: [commit.id],
      );
      expect(rows.single['authored_at'], '2026-01-01 08:30:00');

      // 服务端没有带这两列时按本机规则落库：来源为空、作者时间等于创建时间。
      final plain = await rig.revisions.applyRemoteCommit(
        uid: 'remote-2',
        action: '从其他设备同步',
        actor: 'user',
        changes: [_remoteInsert('r2', '没有来源信息')],
      );
      final plainCommit = plain.commit!;
      expect(plainCommit.originDevice, isNull);
      expect(plainCommit.isRemote, isFalse);
      expect(plainCommit.authoredAt, plainCommit.createdAt);
      final plainRows = await selectRows(
        rig.raw,
        'revision_commit',
        columns: ['authored_at', 'created_at'],
        where: 'id = ?',
        whereArgs: [plainCommit.id],
      );
      expect(
        plainRows.single['authored_at'],
        plainRows.single['created_at'],
        reason: '服务端没有带创建时间时用落库时间',
      );

      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
    });

    test('本机提交的来源设备为空、作者时间等于创建时间', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);

      await _insertMemory(rig, 'm1', '本机写入');
      final head = await rig.engine.headId(rig.raw);
      final commit = await rig.engine.commitById(rig.raw, head);
      expect(commit?.originDevice, isNull);
      expect(commit?.isRemote, isFalse);
      expect(commit?.authoredAt, commit?.createdAt);
      final rows = await selectRows(
        rig.raw,
        'revision_commit',
        columns: ['authored_at', 'created_at'],
        where: 'id = ?',
        whereArgs: [head],
      );
      expect(rows.single['authored_at'], rows.single['created_at']);

      // 初始基线同样按本机提交处理。
      final baseline = await rig.engine.commitById(rig.raw, 0);
      expect(baseline?.originDevice, isNull);
      expect(baseline?.authoredAt, baseline?.createdAt);
    });

    test('行的规范形式与列顺序、表顺序无关，摘要按多重集求和', () {
      final first = {
        'id': RevisionValue.of('a'),
        'content': RevisionValue.of('x'),
      };
      final reversed = {
        'content': RevisionValue.of('x'),
        'id': RevisionValue.of('a'),
      };
      expect(
        canonicalRevisionRow('memory', 'a', first),
        canonicalRevisionRow('memory', 'a', reversed),
        reason: '列按名字排序，声明顺序不影响行的规范形式',
      );
      expect(
        revisionRowHash('memory', 'a', first),
        revisionRowHash('memory', 'a', reversed),
      );

      // 表名、主键与内容一起决定行哈希，任何一项不同都不是同一行。
      expect(
        revisionRowHash('memory', 'a', first),
        isNot(revisionRowHash('memory', 'b', first)),
      );
      expect(
        revisionRowHash('memory', 'a', first),
        isNot(revisionRowHash('learning_goal', 'a', first)),
      );
      expect(
        revisionRowHash('memory', 'a', first),
        isNot(
          revisionRowHash('memory', 'a', {
            'id': RevisionValue.of('a'),
            'content': RevisionValue.of('y'),
          }),
        ),
      );

      // 投影的遍历顺序不影响摘要：求和可交换。
      final left = <String, Map<String, TypedRow>>{
        'memory': {'a': first, 'b': reversed},
        'learning_goal': {'g': first},
      };
      final right = <String, Map<String, TypedRow>>{
        'learning_goal': {'g': first},
        'memory': {'b': reversed, 'a': first},
      };
      expect(revisionStateDigest(left), revisionStateDigest(right));
      expect(
        revisionStateDigest(left),
        isNot(revisionStateDigest(<String, Map<String, TypedRow>>{})),
      );
    });

    test('同一状态按增量累加与整库重算得到同一个摘要', () {
      final before = <String, Map<String, TypedRow>>{
        'memory': {
          'm1': {
            'id': RevisionValue.of('m1'),
            'content': RevisionValue.of('旧'),
          },
          'm2': {
            'id': RevisionValue.of('m2'),
            'content': RevisionValue.of('保留'),
          },
        },
      };
      final after = <String, Map<String, TypedRow>>{
        'memory': {
          'm2': {
            'id': RevisionValue.of('m2'),
            'content': RevisionValue.of('保留'),
          },
          'm3': {
            'id': RevisionValue.of('m3'),
            'content': RevisionValue.of('新'),
          },
        },
      };
      // 采集路径的增量：删除 m1（减）、新增 m3（加）。
      final delta =
          (revisionStateDigestValue(before) -
              revisionRowHashValue('memory', 'm1', before['memory']!['m1']!) +
              revisionRowHashValue('memory', 'm3', after['memory']!['m3']!)) %
          revisionDigestModulus;
      expect(
        revisionStateDigestHex(delta),
        revisionStateDigest(after),
        reason: '减去旧行哈希、加上新行哈希，等于对最终状态整库重算',
      );
    });
  });

  group('哈希链（3.10）', () {
    test('正常历史逐条可校验，锚点在没有裁剪时是初值', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);

      expect(await rig.revisions.chainAnchor(), revisionChainGenesis);
      for (var index = 1; index <= 3; index++) {
        await _insertMemory(rig, 'm$index', '记忆 $index');
      }
      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
      expect(report.isClean, isTrue);
      expect(report.checkedCommits, 4, reason: '初始基线加三条写入');
      expect(report.commitId, await rig.engine.headId(rig.raw));

      // 每条提交都接在前一条的哈希上。
      final commits = await rig.engine.commits(rig.raw);
      expect(commits.last.hash, isNot(revisionChainGenesis));
      for (var index = 0; index < commits.length - 1; index++) {
        final child = commits[index];
        final parent = commits[index + 1];
        expect(child.parentId, parent.id);
        expect(child.parentHash, parent.hash);
      }
    });

    test('篡改变更明细之后哈希校验失败', () async {
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
        ['{"content":{"t":"text","v":"被篡改"}}', head, change['seq']],
      );

      final report = await rig.revisions.verifyIntegrity();
      expect(report.isClean, isFalse);
      expect(
        report.problems.any((problem) => problem.contains('哈希')),
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
        report.problems.any((problem) => problem.contains('摘要')),
        isTrue,
        reason: report.summary,
      );
      expect(
        report.problems.any((problem) => problem.contains('哈希')),
        isFalse,
        reason: '哈希链本身没有动过',
      );
    });

    test('篡改提交身份或父哈希都能发现', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '内容');
      final head = await rig.engine.headId(rig.raw);

      await rig.raw.execute(
        "UPDATE revision_commit SET uid = 'tampered-uid' WHERE id = ?",
        [head],
      );
      var report = await rig.revisions.verifyIntegrity();
      expect(
        report.problems.any((problem) => problem.contains('哈希')),
        isTrue,
        reason: report.summary,
      );

      // 把父哈希改回初值：自己的哈希与父提交的链接都会对不上。
      await rig.raw.execute(
        'UPDATE revision_commit SET parent_hash = ? WHERE id = ?',
        [revisionChainGenesis, head],
      );
      report = await rig.revisions.verifyIntegrity();
      expect(
        report.problems.any((problem) => problem.contains('父哈希')),
        isTrue,
        reason: report.summary,
      );
    });

    test('裁剪之后最早保留提交记录的父哈希成为锚点，更早的历史不再校验', () async {
      final clock = MutableTestClock(DateTime(2026, 1, 1, 9));
      final rig = await openTestRig(engine: RevisionEngine(clock: clock.call));
      addTearDown(rig.close);
      for (var index = 1; index <= 5; index++) {
        clock.advance(const Duration(days: 1));
        await _insertMemory(rig, 'm$index', '记忆 $index');
      }
      final hashes = <int, String>{
        for (final commit in await rig.engine.commits(rig.raw))
          commit.id: commit.hash,
      };
      expect(await rig.revisions.chainAnchor(), revisionChainGenesis);

      await rig.engine.prune(rig.raw, retentionDays: 0, maxBytes: 1);

      final kept = await _commitIds(rig);
      expect(kept.length, lessThan(6), reason: '预算为 1 字节时应当删掉一些提交');
      final earliest = kept.first;
      expect(earliest, greaterThan(1), reason: '最早保留的提交之前有被删掉的提交');
      // 锚点就是最早保留提交记录的父哈希，等于被删掉的最后一条提交的哈希。
      expect(await rig.revisions.chainAnchor(), hashes[earliest - 1]);
      final earliestCommit = await rig.engine.commitById(rig.raw, earliest);
      expect(earliestCommit?.parentHash, hashes[earliest - 1]);

      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
    });

    test('清理历史之后哈希链回到初值，摘要按当前投影重算', () async {
      final rig = await openTestRig();
      addTearDown(rig.close);
      await _insertMemory(rig, 'm1', '一');
      await _insertMemory(rig, 'm2', '二');

      await rig.engine.clearHistory(rig.raw);

      final kept = await _commitIds(rig);
      expect(kept, hasLength(1));
      final commit = await rig.engine.commitById(rig.raw, kept.single);
      expect(commit?.kind, RevisionKind.baseline);
      expect(commit?.parentHash, revisionChainGenesis);
      expect(await rig.revisions.chainAnchor(), revisionChainGenesis);
      await _expectDigestMatchesHead(rig, reason: '清理历史之后');
      final report = await rig.revisions.verifyIntegrity();
      expect(report.problems, isEmpty, reason: report.summary);
      expect(report.checkedCommits, 1);
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
  });
}
