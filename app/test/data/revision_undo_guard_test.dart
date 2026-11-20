import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/domain/rules/time_format.dart';

import '../support/test_db.dart';

/// 全量补建图片缓存时抛错的替身：撤销已经生效，只应返回提示。
class _FailingCache extends AttachmentCache {
  _FailingCache(String filesDir) : super(filesDir: () => filesDir);

  @override
  Future<void> rebuild(RawExecutor executor, AssetStore assets) async {
    throw StateError('模拟图片缓存写入失败');
  }
}

void main() {
  Future<void> insertMemory(TestRig rig, String id, {String? content}) {
    return insertRow(rig.db, 'memory', {
      'id': id,
      'kind': 'preference',
      'content': content ?? '记住的内容',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });
  }

  test('记忆内容修改之后又改有效期，先前的内容修改仍可撤销', () async {
    final now = DateTime(2026, 11, 10, 12);
    final rig = await openTestRigWithUndoRules(clock: () => now);
    addTearDown(rig.close);
    await insertMemory(rig, 'memory-1', content: '原来记下的内容');

    await rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {'content': '改过的内容', 'updated_at': '2026-11-10 10:00:00'},
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
      label: editMemoryAction,
    );
    final contentCommit = await rig.engine.headId(rig.raw);

    // 之后只改有效期，另一次写入顺手改到的 updated_at 不再阻止更早的内容撤销。
    await rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {
          'valid_until': '2026-12-01T00:00:00',
          'updated_at': '2026-11-10 11:00:00',
        },
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
      label: editMemoryAction,
    );

    final result = await rig.revisions.undoCommit(contentCommit);

    expect(result.applied, isTrue, reason: result.message);
    final row = (await selectRows(rig.raw, 'memory')).single;
    expect(row['content'], '原来记下的内容');
    // 之后改的有效期保留，不被更早的撤销抹掉。
    expect(row['valid_until'], '2026-12-01T00:00:00');
    // 维护列写成撤销时刻，不写回旧值，也不早于撤销。
    expect(row['updated_at'], formatDateTime(now));
  });

  test('撤销删除重新插入时 updated_at 写撤销时刻', () async {
    final now = DateTime(2026, 11, 10, 15);
    final rig = await openTestRigWithUndoRules(clock: () => now);
    addTearDown(rig.close);
    await insertMemory(rig, 'memory-2', content: '删掉的记忆');

    await rig.db.command(
      (txn) =>
          deleteRows(txn, 'memory', where: 'id = ?', whereArgs: ['memory-2']),
      label: deleteMemoryAction,
    );
    final deleted = await rig.engine.headId(rig.raw);

    final result = await rig.revisions.undoCommit(deleted);

    expect(result.applied, isTrue, reason: result.message);
    final row = (await selectRows(rig.raw, 'memory')).single;
    expect(row['content'], '删掉的记忆');
    expect(row['created_at'], '2026-11-10 09:00:00');
    expect(row['updated_at'], formatDateTime(now));
  });

  test('白名单由 guard 汇总，未声明的表仍不能撤销', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    await insertRow(rig.db, 'conversation', {
      'id': 'conv-1',
      'title': '一次讨论',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });
    final commit = await rig.engine.headId(rig.raw);
    final history = await rig.revisions.history();

    final reasons = await rig.revisions.undoBlockReasons(history.commits);
    expect(reasons[commit], contains('暂不支持单项撤销'));

    final result = await rig.revisions.undoCommit(commit);
    expect(result.applied, isFalse);
    expect(result.message, contains('暂不支持单项撤销'));
    expect(await selectRows(rig.raw, 'conversation'), hasLength(1));
  });

  test('更正材料页与确认作答记忆仍然开放对应的材料行与作答行', () async {
    final rig = await openTestRigWithUndoRules(
      clock: () => DateTime(2026, 11, 10, 12),
    );
    addTearDown(rig.close);

    await insertRow(rig.db, 'material', {
      'id': 'material-1',
      'title': '概率论讲义',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });
    await insertRow(rig.db, 'material_page', {
      'id': 'page-1',
      'material_id': 'material-1',
      'page_no': 3,
      'content': '旧原文',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });

    // 更正材料页在同一条提交里改材料页与材料行的时间；材料行只随这个动作开放。
    await rig.db.command((txn) async {
      await updateRow(
        txn,
        'material_page',
        {'content': '新原文', 'updated_at': '2026-11-10 10:00:00'},
        where: 'id = ?',
        whereArgs: ['page-1'],
      );
      await updateRow(
        txn,
        'material',
        {'updated_at': '2026-11-10 10:00:00'},
        where: 'id = ?',
        whereArgs: ['material-1'],
      );
    }, label: correctMaterialPageAction);
    final correction = await rig.engine.headId(rig.raw);

    final undone = await rig.revisions.undoCommit(correction);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(
      (await selectRows(rig.raw, 'material_page')).single['content'],
      '旧原文',
    );

    // 确认作答记忆会把作答的帮助字段与建议一起写回；作答行只随这个动作开放。
    await insertRow(rig.db, 'conversation', {
      'id': 'conv-2',
      'title': '作答',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    });
    await rig.db.command(
      (txn) => insertRow(txn, 'attempt', {
        'id': 'attempt-1',
        'conversation_id': 'conv-2',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      label: confirmAttemptMemoryAction,
    );
    final confirmed = await rig.engine.headId(rig.raw);

    final attemptUndone = await rig.revisions.undoCommit(confirmed);
    expect(attemptUndone.applied, isTrue, reason: attemptUndone.message);
    expect(await selectRows(rig.raw, 'attempt'), isEmpty);
  });

  test('远端提交按普通写入适用同一份白名单', () async {
    final rig = await openTestRigWithUndoRules(
      clock: () => DateTime(2026, 11, 10, 12),
    );
    addTearDown(rig.close);

    // 远端提交改到白名单外的表：不能按单项撤销。
    await rig.db.command(
      (txn) => insertRow(txn, 'conversation', {
        'id': 'conv-remote',
        'title': '其他设备的讨论',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      label: '其他设备',
      kind: RevisionKind.remote,
    );
    final blocked = await rig.revisions.undoCommit(
      await rig.engine.headId(rig.raw),
    );
    expect(blocked.applied, isFalse);
    expect(blocked.message, contains('暂不支持单项撤销'));

    // 远端提交改到白名单内的表：照常按反向规则撤销，撤销提交的类型是 undo。
    await rig.db.command(
      (txn) => insertRow(txn, 'memory', {
        'id': 'memory-remote',
        'kind': 'preference',
        'content': '其他设备写入的记忆',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      label: '其他设备',
      kind: RevisionKind.remote,
    );
    final remote = await rig.engine.headId(rig.raw);
    final undone = await rig.revisions.undoCommit(remote);

    expect(undone.applied, isTrue, reason: undone.message);
    expect(undone.commit?.kind, RevisionKind.undo);
    expect(await selectRows(rig.raw, 'memory'), isEmpty);
  });

  test('撤销已生效而图片缓存重建失败时，结果为成功并带提示', () async {
    final cacheDir = await Directory.systemTemp.createTemp(
      'zhixin_undo_cache_',
    );
    addTearDown(() => cacheDir.delete(recursive: true));
    var failures = 0;
    final rig = await openTestRigWithUndoRules(
      cache: _FailingCache(cacheDir.path),
      onCacheFailure: (error, stack) => failures++,
    );
    addTearDown(rig.close);
    await insertMemory(rig, 'memory-3');

    final result = await rig.revisions.undoCommit(
      await rig.engine.headId(rig.raw),
    );

    expect(result.applied, isTrue);
    expect(result.message, contains('已撤销，但图片缓存没有重建完成'));
    expect(failures, 1);
    // 撤销本身已经提交，不能因为缓存失败回滚或报成失败。
    expect(await selectRows(rig.raw, 'memory'), isEmpty);
  });
}
