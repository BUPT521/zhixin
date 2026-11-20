import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/data/revisions/revision_service.dart';

import '../support/test_db.dart';

DateTime _fixedClock() => DateTime(2026, 11, 17, 10);

const String _createdAt = '2026-11-17 10:00:00';

/// 一行完整的记忆记录；远端提交里的新增带整行，删除带的旧行也是整行。
Map<String, RevisionValue> _memoryRow(String id, String content) => {
  'id': RevisionValue.of(id),
  'kind': RevisionValue.of('preference'),
  'content': RevisionValue.of(content),
  'scope': RevisionValue.of(null),
  'source_kind': RevisionValue.of('user'),
  'source_id': RevisionValue.of(null),
  'valid_until': RevisionValue.of(null),
  'status': RevisionValue.of('active'),
  'created_at': RevisionValue.of(_createdAt),
  'updated_at': RevisionValue.of(_createdAt),
};

Map<String, Object?> _memoryValues(String id, String content) => {
  'id': id,
  'kind': 'preference',
  'content': content,
  'scope': null,
  'source_kind': 'user',
  'source_id': null,
  'valid_until': null,
  'status': 'active',
  'created_at': _createdAt,
  'updated_at': _createdAt,
};

Future<void> _insertMemory(TestRig rig, String id, String content) {
  return rig.db.command((txn) async {
    await insertRow(txn, 'memory', _memoryValues(id, content));
  }, label: '新增记忆');
}

Future<void> _updateMemoryContent(TestRig rig, String id, String content) {
  return rig.db.command((txn) async {
    await updateRow(
      txn,
      'memory',
      {'content': content},
      where: 'id = ?',
      whereArgs: [id],
    );
  }, label: '修改记忆');
}

/// 只改维护列；内容列保持不变，用来核对维护列不记冲突。
Future<void> _touchUpdatedAt(TestRig rig, String id, String updatedAt) {
  return rig.db.command((txn) async {
    await updateRow(
      txn,
      'memory',
      {'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [id],
    );
  }, label: '修改记忆');
}

Future<void> _deleteMemory(TestRig rig, String id) {
  return rig.db.command((txn) async {
    await deleteRows(txn, 'memory', where: 'id = ?', whereArgs: [id]);
  }, label: '删除记忆');
}

Future<Map<String, Object?>?> _memory(TestRig rig, String id) async {
  final rows = await rig.raw.rawQuery('SELECT * FROM memory WHERE id = ?', [
    id,
  ]);
  return rows.isEmpty ? null : rows.first;
}

RevisionChange _remoteInsert(String id, String content, {int seq = 1}) =>
    RevisionChange(
      commitId: 0,
      seq: seq,
      table: 'memory',
      rowKey: id,
      op: ChangeOp.insert,
      after: _memoryRow(id, content),
    );

RevisionChange _remoteUpdate(
  String id, {
  required String before,
  required String after,
  int seq = 1,
  String? remoteBeforeUpdatedAt,
  String? remoteAfterUpdatedAt,
}) => RevisionChange(
  commitId: 0,
  seq: seq,
  table: 'memory',
  rowKey: id,
  op: ChangeOp.update,
  before: {
    'content': RevisionValue.of(before),
    if (remoteBeforeUpdatedAt != null)
      'updated_at': RevisionValue.of(remoteBeforeUpdatedAt),
  },
  after: {
    'content': RevisionValue.of(after),
    if (remoteAfterUpdatedAt != null)
      'updated_at': RevisionValue.of(remoteAfterUpdatedAt),
  },
);

RevisionChange _remoteDelete(
  String id, {
  required String before,
  int seq = 1,
}) => RevisionChange(
  commitId: 0,
  seq: seq,
  table: 'memory',
  rowKey: id,
  op: ChangeOp.delete,
  before: _memoryRow(id, before),
);

Future<RemoteApplyResult> _apply(
  TestRig rig,
  String uid,
  List<RevisionChange> changes,
) => rig.revisions.applyRemoteCommit(
  uid: uid,
  action: '从其他设备同步',
  actor: 'user',
  changes: changes,
);

void main() {
  test('远端更新撞上本机同时改过的列时记 concurrent_update 并写入远端值', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机旧值');
    await _updateMemoryContent(rig, 'm1', '本机新值');

    final applied = await _apply(rig, 'remote-update', [
      _remoteUpdate('m1', before: '远端旧值', after: '远端新值'),
    ]);
    expect(applied.skipped, 0);
    expect(applied.duplicate, isFalse);
    expect(applied.commit, isNotNull);
    expect(applied.commit!.kind, RevisionKind.remote);
    expect(applied.commit!.conflictCount, 1);

    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.table, 'memory');
    expect(conflict.rowKey, 'm1');
    expect(conflict.column, 'content');
    expect(conflict.reason, RevisionConflict.concurrentUpdate);
    expect(conflict.local['content']?.value, '本机新值');
    expect(conflict.remoteBefore?['content']?.value, '远端旧值');
    expect(conflict.remoteAfter['content']?.value, '远端新值');
    expect(conflict.isResolved, isFalse);

    // 后到覆盖先到：本机值被远端值替换，冲突记录留着原值。
    final row = await _memory(rig, 'm1');
    expect(row!['content'], '远端新值');
  });

  test('远端新增撞上本机已有同一主键时记 insert_collision 并覆盖整行', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机值');

    final applied = await _apply(rig, 'remote-insert', [
      _remoteInsert('m1', '远端值'),
    ]);
    expect(applied.skipped, 0);
    expect(applied.commit!.conflictCount, 1);

    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.reason, RevisionConflict.insertCollision);
    expect(conflict.column, isNull);
    expect(conflict.local['content']?.value, '本机值');
    // 远端新增没有旧行；库里这一列可空，读回来是空行。
    expect(conflict.remoteBefore, isEmpty);
    expect(conflict.remoteAfter['content']?.value, '远端值');

    final row = await _memory(rig, 'm1');
    expect(row!['content'], '远端值');
  });

  test('远端删除本机改过的行时记 deleted_remotely_modified 并照常删除', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '原值');
    await _updateMemoryContent(rig, 'm1', '本机改过');

    final applied = await _apply(rig, 'remote-delete', [
      _remoteDelete('m1', before: '原值'),
    ]);
    expect(applied.skipped, 0);
    expect(applied.commit!.conflictCount, 1);

    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.reason, RevisionConflict.deletedRemotelyModified);
    expect(conflict.column, isNull);
    expect(conflict.local['content']?.value, '本机改过');
    expect(conflict.remoteBefore?['content']?.value, '原值');
    expect(conflict.remoteAfter, isEmpty);

    expect(await _memory(rig, 'm1'), isNull);
  });

  test('本机已删除的行被远端更新时记 deleted_locally 并跳过写入', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机值');
    await _deleteMemory(rig, 'm1');

    // 这条远端提交里还有一条能真正写入的新增，否则本机没有净变化、不形成
    // 提交，也就没有可以挂冲突记录的提交行。
    final applied = await _apply(rig, 'remote-deleted-locally', [
      _remoteUpdate('m1', before: '本机值', after: '远端新值', seq: 1),
      _remoteInsert('m2', '另一条', seq: 2),
    ]);
    expect(applied.skipped, 1);
    expect(applied.commit, isNotNull);
    expect(applied.commit!.conflictCount, 1);

    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.reason, RevisionConflict.deletedLocally);
    expect(conflict.rowKey, 'm1');
    expect(conflict.local['content']?.value, '远端新值');
    expect(conflict.remoteBefore?['content']?.value, '本机值');
    expect(conflict.remoteAfter['content']?.value, '远端新值');

    // 本机删除保留：对不上的更新跳过，同一批里的新增照常写入。
    expect(await _memory(rig, 'm1'), isNull);
    expect((await _memory(rig, 'm2'))!['content'], '另一条');

    // 没有可以写回的本机值：接口返回空并保留记录，界面据此说明情况。
    expect(await rig.revisions.keepLocal(conflict.id), isNull);
    expect(await rig.revisions.conflicts(), hasLength(1));
  });

  test('keepLocal 把被远端删除的本机整行重新插入', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '原值');
    await _updateMemoryContent(rig, 'm1', '本机改过');
    await _apply(rig, 'remote-delete', [_remoteDelete('m1', before: '原值')]);
    expect(await _memory(rig, 'm1'), isNull);
    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.reason, RevisionConflict.deletedRemotelyModified);

    final commit = await rig.revisions.keepLocal(conflict.id);
    expect(commit, isNotNull);
    final row = await _memory(rig, 'm1');
    expect(row, isNotNull);
    expect(row!['content'], '本机改过');
    expect(row['status'], 'active');
    expect(await rig.revisions.conflicts(), isEmpty);
  });

  test('keepLocal 把冲突里的本机值作为普通写入提交写回并标记已处理', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机旧值');
    await _updateMemoryContent(rig, 'm1', '本机新值');
    await _apply(rig, 'remote-update', [
      _remoteUpdate('m1', before: '远端旧值', after: '远端新值'),
    ]);
    final conflict = (await rig.revisions.conflicts()).single;
    final headBefore = await rig.engine.headId(rig.raw);

    final commit = await rig.revisions.keepLocal(conflict.id);
    expect(commit, isNotNull);
    expect(commit!.kind, RevisionKind.write);
    expect(commit.action, '保留本机修改');

    // 本机值恢复，冲突标为已处理，记录指回这条提交。
    expect((await _memory(rig, 'm1'))!['content'], '本机新值');
    expect(await rig.revisions.conflicts(), isEmpty);
    final resolved = (await rig.revisions.conflicts(unresolved: false)).single;
    expect(resolved.resolvedCommitId, commit.id);

    // 这条提交出现在待推送范围里；远端提交不在其中。
    final pending = await rig.revisions.commitsAfter(headBefore);
    expect(pending.map((item) => item.id), contains(commit.id));

    // 已经处理过、以及不存在的记录都返回空。
    expect(await rig.revisions.keepLocal(conflict.id), isNull);
    expect(await rig.revisions.keepLocal(9999), isNull);
  });
  test('本机已删的覆盖记录可以忽略，其余冲突不能这样消解', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机旧值');
    await _deleteMemory(rig, 'm1');
    // 同一批里要有一条能真正写入的变化，否则没有净变化、不形成提交，冲突
    // 也就没有可以挂载的提交行。
    await _apply(rig, 'remote-update', [
      _remoteUpdate('m1', before: '本机旧值', after: '远端新值', seq: 1),
      _remoteInsert('m2', '另一条', seq: 2),
    ]);

    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.reason, RevisionConflict.deletedLocally);
    // 本机已经删掉这一行，没有可以写回的值。
    expect(await rig.revisions.keepLocal(conflict.id), isNull);

    expect(await rig.revisions.dismissConflict(conflict.id), isTrue);
    expect(await rig.revisions.conflicts(), isEmpty);
    expect(await _memory(rig, 'm1'), isNull);
    // 已经忽略过的记录再操作返回假，不存在的记录也是。
    expect(await rig.revisions.dismissConflict(conflict.id), isFalse);
    expect(await rig.revisions.dismissConflict(9999), isFalse);
  });

  test('并发更新这类要写回本机值的冲突不能用忽略消解', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机旧值');
    await _updateMemoryContent(rig, 'm1', '本机新值');
    await _apply(rig, 'remote-update', [
      _remoteUpdate('m1', before: '远端旧值', after: '远端新值'),
    ]);

    final conflict = (await rig.revisions.conflicts()).single;
    expect(conflict.reason, RevisionConflict.concurrentUpdate);
    expect(await rig.revisions.dismissConflict(conflict.id), isFalse);
    expect(await rig.revisions.conflicts(), hasLength(1));
  });

  test('远端更新只差维护列时不记冲突，冲突记录只留内容列', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '本机旧值');
    // 本机只改过维护列：内容与远端的旧值一致，只有 updated_at 各写了一次。
    await _touchUpdatedAt(rig, 'm1', '2026-11-17 10:05:00');

    final applied = await _apply(rig, 'remote-bookkeeping', [
      _remoteUpdate(
        'm1',
        before: '本机旧值',
        after: '远端新值',
        remoteBeforeUpdatedAt: _createdAt,
        remoteAfterUpdatedAt: '2026-11-17 10:06:00',
      ),
    ]);
    expect(applied.skipped, 0);
    // 内容列按三方比较不冲突（本机值就是远端旧值）；维护列按合并驱动处理，
    // 远端的值照常写入但不记冲突，界面上不再出现“更新时间被覆盖”。
    expect(applied.commit!.conflictCount, 0, reason: '维护列不记冲突');
    expect(await rig.revisions.conflicts(), isEmpty);
    expect((await _memory(rig, 'm1'))!['content'], '远端新值');
    expect((await _memory(rig, 'm1'))!['updated_at'], '2026-11-17 10:06:00');
  });

  test('远端新增撞上本机同一主键、只有维护列不同时也不记冲突', () async {
    final rig = await openTestRig(clock: _fixedClock);
    addTearDown(rig.close);
    await _insertMemory(rig, 'm1', '同样的内容');
    await _touchUpdatedAt(rig, 'm1', '2026-11-17 10:05:00');

    final applied = await _apply(rig, 'remote-insert-bookkeeping', [
      _remoteInsert('m1', '同样的内容'),
    ]);
    expect(applied.skipped, 0);
    // 内容列一致、只有维护列不同：不重写本机行，也不记“新增撞上同一主键”。
    expect(applied.commit, isNull);
    expect(await rig.revisions.conflicts(), isEmpty);
    expect((await _memory(rig, 'm1'))!['content'], '同样的内容');
    expect((await _memory(rig, 'm1'))!['updated_at'], '2026-11-17 10:05:00');
  });
}
