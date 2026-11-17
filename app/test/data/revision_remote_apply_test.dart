import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/revisions/revision_models.dart';

import '../support/test_db.dart';

RevisionChange _insertMemory(String id, String content) => RevisionChange(
  commitId: 0,
  seq: 1,
  table: 'memory',
  rowKey: id,
  op: 'insert',
  after: {
    'id': RevisionValue.of(id),
    'kind': RevisionValue.of('preference'),
    'content': RevisionValue.of(content),
    'scope': RevisionValue.of(null),
    'source_kind': RevisionValue.of('user'),
    'source_id': RevisionValue.of(null),
    'valid_until': RevisionValue.of(null),
    'status': RevisionValue.of('active'),
    'created_at': RevisionValue.of('2026-11-17 10:00:00'),
    'updated_at': RevisionValue.of('2026-11-17 10:00:00'),
  },
);

RevisionChange _updateMemory(String id, String content) => RevisionChange(
  commitId: 0,
  seq: 2,
  table: 'memory',
  rowKey: id,
  op: 'update',
  before: {'content': RevisionValue.of('旧')},
  after: {'content': RevisionValue.of(content)},
);

void main() {
  test('应用远端新增、更新与删除，并形成一条本机提交', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);

    final applied = await rig.revisions.applyRemoteCommit(
      requestId: 'remote-1',
      action: '从其他设备同步',
      actor: 'user',
      changes: [_insertMemory('m1', '旧')],
    );
    expect(applied.commit, isNotNull);
    expect(applied.duplicate, isFalse);
    var rows = await rig.raw.rawQuery(
      'SELECT content FROM memory WHERE id = ?',
      ['m1'],
    );
    expect(rows.single['content'], '旧');

    final updated = await rig.revisions.applyRemoteCommit(
      requestId: 'remote-2',
      action: '从其他设备同步',
      actor: 'user',
      changes: [_updateMemory('m1', '新')],
    );
    expect(updated.commit, isNotNull);
    rows = await rig.raw.rawQuery('SELECT content FROM memory WHERE id = ?', [
      'm1',
    ]);
    expect(rows.single['content'], '新');

    // 同一个请求编号重复下发时不再生成第二条提交。
    final duplicate = await rig.revisions.applyRemoteCommit(
      requestId: 'remote-2',
      action: '从其他设备同步',
      actor: 'user',
      changes: [_updateMemory('m1', '新')],
    );
    expect(duplicate.duplicate, isTrue);
    expect(duplicate.commit?.requestId, 'remote-2');

    final deleted = await rig.revisions.applyRemoteCommit(
      requestId: 'remote-3',
      action: '从其他设备同步',
      actor: 'user',
      changes: [
        RevisionChange(
          commitId: 0,
          seq: 1,
          table: 'memory',
          rowKey: 'm1',
          op: 'delete',
          before: {'id': RevisionValue.of('m1')},
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
      requestId: 'remote-x',
      action: '从其他设备同步',
      actor: 'user',
      changes: [
        _updateMemory('missing', 'x'),
        RevisionChange(
          commitId: 0,
          seq: 2,
          table: 'memory',
          rowKey: 'missing',
          op: 'delete',
          before: {'id': RevisionValue.of('missing')},
        ),
      ],
    );
    expect(skipped.skipped, 2);
    expect(skipped.commit, isNull);

    await expectLater(
      rig.revisions.applyRemoteCommit(
        requestId: 'remote-y',
        action: '从其他设备同步',
        actor: 'user',
        changes: [
          RevisionChange(
            commitId: 0,
            seq: 1,
            table: 'not_a_table',
            rowKey: 'x',
            op: 'delete',
            before: {'id': RevisionValue.of('x')},
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
