import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/revisions/asset_store.dart';
import 'package:zhixin/data/revisions/revision_actions.dart';
import 'package:zhixin/data/revisions/revision_models.dart';
import 'package:zhixin/domain/models/chat_message_payload.dart';
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
      'kind': 'semantic',
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
      kind: RevisionKind.write,
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
        'kind': 'semantic',
        'content': '其他设备写入的记忆',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      label: '其他设备',
      kind: RevisionKind.write,
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
    expect(result.message, contains('已撤销这次操作，但图片缓存没有重建完成'));
    expect(failures, 1);
    // 撤销本身已经提交，不能因为缓存失败回滚或报成失败。
    expect(await selectRows(rig.raw, 'memory'), isEmpty);
  });

  /// 读一条记忆；不存在时为空。
  Future<Map<String, Object?>?> memoryRow(TestRig rig, String id) async {
    final rows = await selectRows(
      rig.raw,
      'memory',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 读一条消息的结构化补充。
  Future<ChatMessagePayload?> messagePayload(
    TestRig rig,
    String messageId,
  ) async {
    final rows = await selectRows(
      rig.raw,
      'message',
      columns: ['structured_json'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return ChatMessagePayload.decode(
      rows.isEmpty ? null : rows.first['structured_json'] as String?,
    );
  }

  /// 安排页能从提交历史里找到的 AI 改动编号。
  Future<Set<int>> receiptIds(TestRig rig) async {
    final commits = await rig.revisions.receiptCommits(
      actions: receiptActions,
      tables: const {'memory', 'plan_item'},
    );
    return {for (final commit in commits) commit.id};
  }

  test('撤销之后再撤销就是重做：按正向写回，提交回指那条撤销提交', () async {
    final now = DateTime(2026, 11, 10, 12);
    final rig = await openTestRigWithUndoRules(clock: () => now);
    addTearDown(rig.close);
    await insertMemory(rig, 'memory-1', content: '原来记下的内容');

    await rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {'content': '改过的内容'},
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
      label: editMemoryAction,
    );
    final edit = await rig.engine.headId(rig.raw);

    final undone = await rig.revisions.undoCommit(edit);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memoryRow(rig, 'memory-1'))!['content'], '原来记下的内容');
    expect(undone.commit!.revertedCommitId, edit);
    expect(await rig.revisions.activeCommits([edit]), isEmpty);

    // 撤销一条撤销提交就是重做：按正向写回它撤销掉的内容。
    final redone = await rig.revisions.undoCommit(undone.commit!.id);
    expect(redone.applied, isTrue, reason: redone.message);
    expect(redone.message, '已重做这次撤销');
    expect(redone.commit!.kind, RevisionKind.undo);
    expect(redone.commit!.action, '重做操作');
    expect(redone.commit!.revertedCommitId, undone.commit!.id);
    final row = (await memoryRow(rig, 'memory-1'))!;
    expect(row['content'], '改过的内容');
    // 重做与撤销一样把维护列写成动作发生的时刻，不写回旧值。
    expect(row['updated_at'], formatDateTime(now));

    // 重做之后原提交重新生效；已经重做过的撤销提交不能再撤销一次。
    expect(await rig.revisions.activeCommits([edit]), {edit});
    final history = await rig.revisions.history();
    final reasons = await rig.revisions.undoBlockReasons(history.commits);
    expect(reasons[edit], isNull);
    expect(reasons[undone.commit!.id], '这次撤销已经重做');
    expect(reasons[redone.commit!.id], isNull);
    final undoable = {
      for (final commit in await rig.revisions.undoableCommits()) commit.id,
    };
    expect(undoable, contains(edit));
    expect(undoable, isNot(contains(undone.commit!.id)));
    expect(undoable, isNot(contains(redone.commit!.id)));
  });

  test('撤销、重做、再撤销：链上的写回不算后续修改，原提交可以再撤销', () async {
    final now = DateTime(2026, 11, 10, 12);
    final rig = await openTestRigWithUndoRules(clock: () => now);
    addTearDown(rig.close);
    await insertMemory(rig, 'memory-1', content: '原来记下的内容');

    await rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {'content': '改过的内容'},
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
      label: editMemoryAction,
    );
    final edit = await rig.engine.headId(rig.raw);

    final undone = await rig.revisions.undoCommit(edit);
    expect(undone.applied, isTrue, reason: undone.message);
    final redone = await rig.revisions.undoCommit(undone.commit!.id);
    expect(redone.applied, isTrue, reason: redone.message);

    // 重做之后原提交重新可以撤销：撤销链上自己的写回不阻止再撤销。
    final undoneAgain = await rig.revisions.undoCommit(edit);
    expect(undoneAgain.applied, isTrue, reason: undoneAgain.message);
    expect(undoneAgain.message, '已撤销这次操作');
    expect(undoneAgain.commit!.revertedCommitId, edit);
    expect(undoneAgain.commit!.action, '撤销操作');
    expect((await memoryRow(rig, 'memory-1'))!['content'], '原来记下的内容');

    final history = await rig.revisions.history();
    final reasons = await rig.revisions.undoBlockReasons(history.commits);
    expect(reasons[edit], '这次操作已经撤销');
    // 这次重做还没有被撤销，可以再撤销（回到撤销后的状态）。
    expect(reasons[redone.commit!.id], isNull);
    expect(reasons[undoneAgain.commit!.id], isNull);
  });

  test('撤销删除再重做：写回的行按正向再删一次', () async {
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
    final undone = await rig.revisions.undoCommit(deleted);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memoryRow(rig, 'memory-2'))!['content'], '删掉的记忆');

    // 重做这次撤销就是再删一次；维护列仍写成动作发生的时刻。
    final redone = await rig.revisions.undoCommit(undone.commit!.id);
    expect(redone.applied, isTrue, reason: redone.message);
    expect(await memoryRow(rig, 'memory-2'), isNull);
  });

  test('撤销之后同一格又被改过时拒绝重做', () async {
    final rig = await openTestRigWithUndoRules(
      clock: () => DateTime(2026, 11, 10, 12),
    );
    addTearDown(rig.close);
    await insertMemory(rig, 'memory-1', content: '原来记下的内容');

    await rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {'content': '改过的内容'},
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
      label: editMemoryAction,
    );
    final edit = await rig.engine.headId(rig.raw);
    final undone = await rig.revisions.undoCommit(edit);
    expect(undone.applied, isTrue, reason: undone.message);

    // 撤销之后用户又改了同一列：重做会覆盖这次修改，必须拒绝。
    await rig.db.command(
      (txn) => updateRow(
        txn,
        'memory',
        {'content': '之后又改的内容'},
        where: 'id = ?',
        whereArgs: ['memory-1'],
      ),
      label: editMemoryAction,
    );
    final headBefore = await rig.engine.headId(rig.raw);

    final redone = await rig.revisions.undoCommit(undone.commit!.id);
    expect(redone.applied, isFalse);
    expect(redone.message, '这次撤销之后，同一项内容又被修改过，不能重做');
    expect((await memoryRow(rig, 'memory-1'))!['content'], '之后又改的内容');
    expect(await rig.engine.headId(rig.raw), headBefore);
  });

  test('重做不恢复消息里的回执，回执状态按 activeCommits 重新判断', () async {
    final rig = await openTestRigWithUndoRules(
      clock: () => DateTime(2026, 11, 10, 12),
    );
    addTearDown(rig.close);

    await rig.db.command(
      (txn) => insertRow(txn, 'conversation', {
        'id': 'conversation-1',
        'title': '讨论',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      label: '新建讨论',
    );
    await rig.db.command(
      (txn) => insertRow(txn, 'message', {
        'id': 'message-1',
        'conversation_id': 'conversation-1',
        'role': 'assistant',
        'content': '回答',
        'created_at': '2026-11-10 09:00:00',
      }),
      label: '写入回答',
    );
    // 接受下一步建议：学习事项与消息里的回执在同一条提交里写入。
    final accepted = await rig.db.commandOutcome((txn) async {
      final commitId = await rig.engine.reserveCommitId(txn);
      await insertRow(txn, 'plan_item', {
        'id': 'item-1',
        'title': '重做第 8 题',
        'status': 'todo',
        'origin_json': jsonEncode({
          'message_id': 'message-1',
          'step_id': 'step-1',
        }),
        'created_at': '2026-11-10 09:30:00',
        'updated_at': '2026-11-10 09:30:00',
      });
      final payload = const ChatMessagePayload().acceptedStep(
        '重做第 8 题',
        stepId: 'step-1',
        commitId: commitId,
      );
      await updateRow(
        txn,
        'message',
        {'structured_json': payload.encode()},
        where: 'id = ?',
        whereArgs: ['message-1'],
      );
      return commitId;
    }, label: acceptNextStepAction);
    final acceptCommit = accepted.commit!.id;
    expect(accepted.value, acceptCommit);

    final before = await messagePayload(rig, 'message-1');
    expect(before!.operations.single.commitId, acceptCommit);
    expect(await receiptIds(rig), contains(acceptCommit));

    // 撤销：学习事项删除，回执与已接受的标题一起清掉。
    final undone = await rig.revisions.undoCommit(acceptCommit);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await selectRows(rig.raw, 'plan_item'), isEmpty);
    final afterUndo = await messagePayload(rig, 'message-1');
    // 回执与已接受的标题都清掉之后结构化补充整段为空。
    expect(afterUndo?.operations ?? const [], isEmpty);
    expect(afterUndo?.acceptedStepIds ?? const <String>{}, isEmpty);
    expect(await receiptIds(rig), isNot(contains(acceptCommit)));

    // 重做：学习事项写回，旧回执不恢复。
    final redone = await rig.revisions.undoCommit(undone.commit!.id);
    expect(redone.applied, isTrue, reason: redone.message);
    expect(await selectRows(rig.raw, 'plan_item'), hasLength(1));
    final afterRedo = await messagePayload(rig, 'message-1');
    expect(afterRedo?.operations ?? const [], isEmpty, reason: '重做不恢复旧回执');
    expect(afterRedo?.acceptedStepIds ?? const <String>{}, isEmpty);
    // 原提交重新生效，安排页按提交历史重新给出回执。
    expect(await rig.revisions.activeCommits([acceptCommit]), {acceptCommit});
    expect(await receiptIds(rig), contains(acceptCommit));
  });
}
