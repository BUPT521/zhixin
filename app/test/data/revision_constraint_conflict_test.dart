import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/domain/models/revision_models.dart';

import '../support/test_db.dart';

/// 审查 S18 的两层回归用例：列组整组写入，以及远端应用撞上唯一约束时的处置。
///
/// 缺陷在这两种情形下表现为远端应用直接抛约束错误：跨列 CHECK 被半行更新
/// 破坏时整条提交回滚，下一轮同步重试同一条提交，同步一直停在那里。

const String _stamp = '2026-11-17 10:00:00';

Map<String, Object?> _material(String id) => {
  'id': id,
  'title': '讲义',
  'kind': 'text',
  'created_at': _stamp,
  'updated_at': _stamp,
};

Map<String, Object?> _page(
  String id,
  String materialId,
  int pageNo,
  String content,
) => {
  'id': id,
  'material_id': materialId,
  'page_no': pageNo,
  'content': content,
  'created_at': _stamp,
  'updated_at': _stamp,
};

Map<String, Object?> _planItem(
  String id,
  String planId, {
  required int seq,
  required String title,
}) => {
  'id': id,
  'study_plan_id': planId,
  'seq': seq,
  'title': title,
  'created_at': _stamp,
  'updated_at': _stamp,
};

Future<void> _insert(TestRig rig, String table, Map<String, Object?> row) {
  return rig.db.command((txn) async {
    await insertRow(txn, table, row);
  }, label: '测试写入');
}

Future<Map<String, Object?>?> _row(TestRig rig, String table, String id) async {
  final rows = await rig.raw.rawQuery('SELECT * FROM $table WHERE id = ?', [
    id,
  ]);
  return rows.isEmpty ? null : rows.first;
}

void main() {
  test('跨过零明细的冲突提交，比较仍按变更明细合并', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await _insert(rig, 'material', _material('mat1'));
    await _insert(rig, 'material_page', _page('p-local', 'mat1', 1, '本机写入的正文'));

    // 远端插入撞上本机占着的同一页码：整条提交没有一行写入，但冲突要挂在提交
    // 行上才能在数据版本页提示，于是形成一条没有变更明细的提交。
    final applied = await rig.revisions.applyRemoteCommit(
      uid: 'remote-empty-commit',
      action: '从其他设备同步',
      actor: 'user',
      kind: RevisionKind.write,
      originDevice: 'device-b',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'material_page',
          rowKey: 'p-remote',
          op: ChangeOp.insert,
          after: typedRow(_page('p-remote', 'mat1', 1, '远端写入的正文')),
        ),
      ],
    );
    expect(applied.skipped, 1);
    final conflictHead = await rig.engine.headId(rig.raw);
    expect(
      await selectRows(
        rig.raw,
        'revision_change',
        where: 'commit_id = ?',
        whereArgs: [conflictHead],
      ),
      isEmpty,
      reason: '这条提交只有冲突，没有数据变化',
    );
    final conflictCommit = (await selectRows(
      rig.raw,
      'revision_commit',
      where: 'id = ?',
      whereArgs: [conflictHead],
    )).single;
    expect(conflictCommit['byte_length'], 0, reason: '提交行记下了这次没有变更明细');

    // 冲突提交之后又有一次普通写入：跨过零明细提交的比较仍能用变更明细合并，
    // 不退回两次整库重建，也不把这条提交当成历史损坏。
    await _insert(rig, 'material', _material('mat2'));
    final head = await rig.engine.headId(rig.raw);
    final changes = await rig.engine.foldChanges(rig.raw, 0, head);
    final keys = {
      for (final change in changes)
        '${change.table}/${change.rowKey}/${change.op.value}',
    };
    expect(
      keys,
      containsAll([
        'material/mat1/insert',
        'material/mat2/insert',
        'material_page/p-local/insert',
      ]),
    );
    expect(
      changes.where((change) => change.table == 'material_page'),
      hasLength(1),
    );
  });

  test('两端插入同一份材料的同一页码时跳过远端这一行并记 unique_key_taken', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await _insert(rig, 'material', _material('mat1'));
    await _insert(rig, 'material_page', _page('p-local', 'mat1', 1, '本机写入的正文'));

    final applied = await rig.revisions.applyRemoteCommit(
      uid: 'remote-page-1',
      action: '从其他设备同步',
      actor: 'user',
      kind: RevisionKind.write,
      originDevice: 'device-b',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'material_page',
          rowKey: 'p-remote',
          op: ChangeOp.insert,
          after: typedRow(_page('p-remote', 'mat1', 1, '远端写入的正文')),
        ),
      ],
    );

    expect(applied.skipped, 1, reason: '页码被本机占着，远端这一行跳过');
    expect(applied.adjusted, 0);
    expect(
      await rig.raw.rawQuery('SELECT id FROM material_page'),
      hasLength(1),
      reason: '远端这一行没有写入',
    );
    final conflicts = await rig.revisions.conflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.reason, RevisionConflict.uniqueKeyTaken);
    expect(conflicts.single.table, 'material_page');
    expect(conflicts.single.rowKey, 'p-remote');
  });

  test('两端给同一步骤序号时把本机行改到下一个空号，两行都保留', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await _insert(rig, 'study_plan', {
      'id': 'sp1',
      'title': '系统学习',
      'status': 'active',
      'created_at': _stamp,
      'updated_at': _stamp,
    });
    await _insert(
      rig,
      'plan_item',
      _planItem('it-local', 'sp1', seq: 1, title: '本机的步骤'),
    );

    final applied = await rig.revisions.applyRemoteCommit(
      uid: 'remote-seq-1',
      action: '从其他设备同步',
      actor: 'user',
      kind: RevisionKind.write,
      originDevice: 'device-b',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'plan_item',
          rowKey: 'it-remote',
          op: ChangeOp.insert,
          after: typedRow(
            _planItem('it-remote', 'sp1', seq: 1, title: '远端的步骤'),
          ),
        ),
      ],
    );

    expect(applied.skipped, 0);
    expect(applied.adjusted, 1, reason: '本机这一行改到下一个空号');
    final local = await _row(rig, 'plan_item', 'it-local');
    final remote = await _row(rig, 'plan_item', 'it-remote');
    expect(remote!['seq'], 1, reason: '远端这一行按远端的值写入');
    expect(local!['seq'], 2, reason: '本机这一行改到下一个空号');
    expect(await rig.revisions.conflicts(), isEmpty, reason: '顺序列自动处置，不记冲突');
  });

  test('两端给同一条记忆的同一台设备写使用统计时跳过远端这一行并记 unique_key_taken', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await _insert(rig, 'memory', {
      'id': 'm1',
      'kind': 'semantic',
      'content': '讲解先给例题',
      'scope': null,
      'source_kind': 'user',
      'source_id': null,
      'valid_until': null,
      'status': 'active',
      'created_at': _stamp,
      'updated_at': _stamp,
    });
    await _insert(rig, 'memory_usage', {
      'id': 'u-local',
      'memory_id': 'm1',
      'device_id': 'device-a',
      'recall_count': 1,
      'search_count': 0,
      'updated_at': _stamp,
    });

    // 同一台设备重新克隆之后又推了一次汇总，行键与编号都不是本机这一行，
    // 撞上的是“记忆编号＋设备编号”的唯一约束。
    final applied = await rig.revisions.applyRemoteCommit(
      uid: 'remote-usage-1',
      action: '从其他设备同步',
      actor: 'system',
      kind: RevisionKind.maintenance,
      originDevice: 'device-a',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'memory_usage',
          rowKey: 'u-remote',
          op: ChangeOp.insert,
          after: typedRow({
            'id': 'u-remote',
            'memory_id': 'm1',
            'device_id': 'device-a',
            'recall_count': 2,
            'search_count': 0,
            'updated_at': _stamp,
          }),
        ),
      ],
    );

    expect(applied.skipped, 1, reason: '同一记忆同一设备的行已经在，远端这一行跳过');
    expect(applied.adjusted, 0);
    expect(
      await rig.raw.rawQuery('SELECT id FROM memory_usage'),
      hasLength(1),
      reason: '远端这一行没有写入',
    );
    final conflicts = await rig.revisions.conflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.reason, RevisionConflict.uniqueKeyTaken);
    expect(conflicts.single.table, 'memory_usage');
    expect(conflicts.single.rowKey, 'u-remote');
  });
}
