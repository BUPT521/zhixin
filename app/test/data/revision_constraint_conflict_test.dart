import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

/// 审查 S18 的两层回归用例：列组整组写入，以及远端应用撞上唯一约束时的处置。
///
/// 缺陷在这两种情形下表现为远端应用直接抛约束错误：跨列 CHECK 被半行更新
/// 破坏时整条提交回滚，下一轮同步重试同一条提交，同步一直停在那里。

const String _stamp = '2026-11-17 10:00:00';

Map<String, Object?> _timetable(String id, String start, String end) => {
  'id': id,
  'weekday': 1,
  'start_time': start,
  'end_time': end,
  'title': '线性代数',
  'created_at': _stamp,
  'updated_at': _stamp,
};

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
  test('本机改开始时间、远端只改结束时间时整组写入，跨列 CHECK 不被破坏', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    await _insert(
      rig,
      'timetable_entry',
      _timetable('t1', '2026-11-17 08:00:00', '2026-11-17 10:00:00'),
    );
    // 本机把开始时间改到 09:45，结束时间仍是 10:00，本机的行本身满足约束。
    await rig.db.command((txn) async {
      await updateRow(
        txn,
        'timetable_entry',
        {'start_time': '2026-11-17 09:45:00'},
        where: 'id = ?',
        whereArgs: ['t1'],
      );
    }, label: '修改课表');

    // 采集把整组写进变更明细：只改开始时间，结束时间也要跟着进去。
    final head = await rig.engine.headId(rig.raw);
    final local = await rig.revisions.details(head);
    final localChange = local!.changes.singleWhere(
      (change) => change.table == 'timetable_entry',
    );
    expect(localChange.after!.keys, containsAll(['start_time', 'end_time']));

    // 远端只把结束时间从 10:00 改到 09:30；本机开始时间是 09:45，直接写结束
    // 时间会得到 end <= start 的行。
    final applied = await rig.revisions.applyRemoteCommit(
      uid: 'remote-group-1',
      action: '从其他设备同步',
      actor: 'user',
      kind: RevisionKind.write,
      originDevice: 'device-b',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'timetable_entry',
          rowKey: 't1',
          op: ChangeOp.update,
          before: {
            'start_time': RevisionValue.of('2026-11-17 08:00:00'),
            'end_time': RevisionValue.of('2026-11-17 10:00:00'),
          },
          after: {
            'start_time': RevisionValue.of('2026-11-17 08:00:00'),
            'end_time': RevisionValue.of('2026-11-17 09:30:00'),
          },
        ),
      ],
    );

    expect(applied.skipped, 0);
    final row = await _row(rig, 'timetable_entry', 't1');
    expect(row!['start_time'], '2026-11-17 08:00:00', reason: '整组写入，开始时间用远端整行');
    expect(row['end_time'], '2026-11-17 09:30:00');
    // 本机改过的开始时间被覆盖，记一条冲突供用户写回。
    final conflicts = await rig.revisions.conflicts();
    expect(
      conflicts.map((conflict) => conflict.column),
      contains('start_time'),
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
}
