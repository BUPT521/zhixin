import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

/// 一行远端明细的列值：`null` 表示 SQLite 的空值，其余按原值记类型。
///
/// `RevisionValue.of(null)` 现在不接受空值，构造“某一列是 NULL”的远端行要显式
/// 写 `null`，这里统一换成 `RevisionValue` 的空值表示。
TypedRow _row(Map<String, Object?> columns) => {
  for (final entry in columns.entries)
    entry.key: entry.value is RevisionValue
        ? entry.value! as RevisionValue
        : RevisionValue.of(entry.value),
};

RevisionChange _insertMemory(String id, String content) => RevisionChange(
  commitId: 0,
  seq: 1,
  table: 'memory',
  rowKey: id,
  op: ChangeOp.insert,
  after: _row({
    'id': id,
    'kind': 'semantic',
    'content': content,
    'scope': null,
    'source_kind': 'user',
    'source_id': null,
    'valid_until': null,
    'status': 'active',
    'created_at': '2026-11-17 10:00:00',
    'updated_at': '2026-11-17 10:00:00',
  }),
);

RevisionChange _updateMemory(String id, String content) => RevisionChange(
  commitId: 0,
  seq: 2,
  table: 'memory',
  rowKey: id,
  op: ChangeOp.update,
  before: _row({'content': '旧'}),
  after: _row({'content': content}),
);

void main() {
  test('应用远端新增、更新与删除，并形成一条本机提交', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);

    final applied = await rig.revisions.applyRemoteCommit(
      uid: 'remote-1',
      action: '从其他设备同步',
      actor: 'user',
      changes: [_insertMemory('m1', '旧')],
    );
    expect(applied.commit, isNotNull);
    expect(applied.duplicate, isFalse);
    var rows = await rig.raw.rawQuery(
      'SELECT content, kind FROM memory WHERE id = ?',
      ['m1'],
    );
    expect(rows.single['content'], '旧');
    expect(rows.single['kind'], 'semantic');

    final updated = await rig.revisions.applyRemoteCommit(
      uid: 'remote-2',
      action: '从其他设备同步',
      actor: 'user',
      changes: [_updateMemory('m1', '新')],
    );
    expect(updated.commit, isNotNull);
    rows = await rig.raw.rawQuery('SELECT content FROM memory WHERE id = ?', [
      'm1',
    ]);
    expect(rows.single['content'], '新');

    // 同一个提交身份重复下发时不再生成第二条提交。
    final duplicate = await rig.revisions.applyRemoteCommit(
      uid: 'remote-2',
      action: '从其他设备同步',
      actor: 'user',
      changes: [_updateMemory('m1', '新')],
    );
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.commit?.uid, 'remote-2');

    final deleted = await rig.revisions.applyRemoteCommit(
      uid: 'remote-3',
      action: '从其他设备同步',
      actor: 'user',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'memory',
          rowKey: 'm1',
          op: ChangeOp.delete,
          before: _row({'id': 'm1'}),
        ),
      ],
    );
    expect(deleted.commit, isNotNull);
    expect(
      await rig.raw.rawQuery('SELECT id FROM memory WHERE id = ?', ['m1']),
      isEmpty,
    );
  });

  test('对不上的更新与删除跳过并返回条数，未知表直接报错', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);

    final skipped = await rig.revisions.applyRemoteCommit(
      uid: 'remote-x',
      action: '从其他设备同步',
      actor: 'user',
      changes: [
        _updateMemory('missing', 'x'),
        RevisionChange(
          commitId: 0,
          seq: 2,
          table: 'memory',
          rowKey: 'missing',
          op: ChangeOp.delete,
          before: _row({'id': 'missing'}),
        ),
      ],
    );
    expect(skipped.skipped, 2);
    expect(skipped.commit, isNull);

    await expectLater(
      rig.revisions.applyRemoteCommit(
        uid: 'remote-y',
        action: '从其他设备同步',
        actor: 'user',
        changes: [
          RevisionChange(
            commitId: 0,
            seq: 1,
            table: 'not_a_table',
            rowKey: 'x',
            op: ChangeOp.delete,
            before: _row({'id': 'x'}),
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
