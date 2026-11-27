import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/application/buddy_actions.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

/// 直接写一行记忆；要先有一条现成的记忆时用它，写入路径本身走仓库。
Future<String> _seedMemory(
  TestRig rig, {
  required String id,
  required String kind,
  required String content,
  String? scope,
  String? validUntil,
}) async {
  await insertRow(rig.db, 'memory', {
    'id': id,
    'kind': kind,
    'content': content,
    'scope': scope,
    'source_kind': 'user',
    'valid_until': validUntil,
    'status': 'active',
    'created_at': '2026-11-10T09:00:00',
    'updated_at': '2026-11-10T09:00:00',
  });
  return id;
}

void main() {
  test('把模型给的记忆写进库：三类标签照写，情景跟本次范围，语义与程序保持全局', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);

    final applied = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      memories: memories,
      drafts: const [
        MemoryDraft(kind: MemoryKind.episodic, content: '第 8 题在放缩处卡住'),
        MemoryDraft(kind: MemoryKind.semantic, content: '本周晚上只有半小时'),
        MemoryDraft(kind: MemoryKind.procedural, content: '先给例子再给定义'),
      ],
      sourceKind: MemorySourceKind.message,
      sourceId: 'msg-1',
      scope: memoryGoalScope('goal-1'),
    );
    expect(applied.changes, hasLength(3));
    expect(applied.changes.first.memoryId, isNotNull);

    final stored = {
      for (final memory in await memories.list()) memory.kind: memory,
    };
    expect(
      stored.keys,
      unorderedEquals([
        MemoryKind.episodic,
        MemoryKind.semantic,
        MemoryKind.procedural,
      ]),
    );
    expect(stored[MemoryKind.episodic]!.scope, memoryGoalScope('goal-1'));
    expect(stored[MemoryKind.semantic]!.scope, isNull);
    expect(stored[MemoryKind.procedural]!.scope, isNull);
    expect(stored[MemoryKind.episodic]!.sourceKind, MemorySourceKind.message);
    expect(stored[MemoryKind.episodic]!.sourceId, 'msg-1');
    // 写入后按同一条提交整组撤销。
    final undone = await rig.revisions.undoCommit(
      applied.changes.first.commitId,
    );
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await memories.list(), isEmpty);
  });

  test('同样的记忆再写一次不重复写入，超长的按上限跳过', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final transactions = WriteTransactions(rig.db, revisions: rig.engine);

    Future<ApplyResult> apply(List<MemoryDraft> drafts) => applyMemoryDrafts(
      transactions: transactions,
      memories: memories,
      drafts: drafts,
      sourceKind: MemorySourceKind.message,
      sourceId: 'msg-1',
    );

    final first = await apply(const [
      MemoryDraft(kind: MemoryKind.semantic, content: '本周晚上只有半小时'),
    ]);
    expect(first.changes, hasLength(1));
    final again = await apply(const [
      MemoryDraft(kind: MemoryKind.semantic, content: '本周晚上只有半小时'),
    ]);
    expect(again.changes, isEmpty, reason: '同一类、同一范围、同一正文不再写');
    expect(await memories.list(), hasLength(1));

    final tooLong = await apply([
      MemoryDraft(kind: MemoryKind.semantic, content: '长' * 201),
    ]);
    expect(tooLong.changes, isEmpty);
    expect(tooLong.skipped, isNotEmpty);
    expect(await memories.list(), hasLength(1));
  });
  test('已落库的记忆可以按提交撤销', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);

    await insertRow(rig.db, 'memory', {
      'id': 'memory-1',
      'kind': 'semantic',
      'content': '本周晚上只有半小时',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10T09:00:00',
      'updated_at': '2026-11-10T09:00:00',
    });
    final commitId = await rig.engine.headId(rig.raw);

    expect(await memories.activeForContext(now: DateTime.now()), hasLength(1));
    expect(await rig.revisions.activeCommits([commitId]), {commitId});
    final undone = await rig.revisions.undoCommit(commitId);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await memories.activeForContext(now: DateTime.now()), isEmpty);
    expect(await rig.revisions.activeCommits([commitId]), isEmpty);
  });

  test('用户改过的记忆，旧的写入提交不能撤销', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final id = await _seedMemory(
      rig,
      id: 'memory-1',
      kind: 'episodic',
      content: '原有困难',
    );
    final created = (await rig.revisions.undoableCommits()).last;
    await updateRow(
      rig.db,
      'memory',
      {'content': '用户修改后的困难', 'updated_at': '2026-11-10T10:00:00'},
      where: 'id = ?',
      whereArgs: [id],
    );

    final undone = await rig.revisions.undoCommit(created.id);
    expect(undone.applied, isFalse);
    expect(undone.message, '这次操作之后，同一项内容又被修改过，不能撤销');
    expect((await memories.byId(id))!.content, '用户修改后的困难');
    expect(await rig.revisions.activeCommits([created.id]), {created.id});
  });

  test('已有学习场次的事项不能撤销创建', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final itemId = await tasks.createItem(title: '复习题目');
    final created = (await rig.revisions.undoableCommits()).last;
    await insertRow(rig.db, 'study_session', {
      'id': 'follow-up',
      'plan_item_id': itemId,
      'started_at': '2026-11-08T10:00:00Z',
      'created_at': '2026-11-08T10:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
    });

    final undone = await rig.revisions.undoCommit(created.id);
    expect(undone.applied, isFalse);
    expect(undone.message, '这项任务已有学习记录，不能撤销');
    expect(
      await selectRows(
        rig.db,
        'plan_item',
        where: 'id = ?',
        whereArgs: [itemId],
      ),
      hasLength(1),
    );
    expect(await selectRows(rig.db, 'study_session'), hasLength(1));
    expect(await rig.revisions.activeCommits([created.id]), {created.id});
  });

  test('记忆去重按正文逐字比较，过期记录不参与', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    await _seedMemory(
      rig,
      id: 'memory-1',
      kind: 'episodic',
      content: '同一内容',
      scope: memoryGoalScope('goal-1'),
      validUntil: DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
    );

    final identities = await memories.activeIdentities(DateTime.now());
    expect(identities, isEmpty, reason: '过期的记录不进入去重比较');
    final active = await _seedMemory(
      rig,
      id: 'memory-2',
      kind: 'episodic',
      content: '已经写过的一条',
    );
    await updateRow(
      rig.db,
      'memory',
      {
        'content': '同一内容',
        'scope': memoryGoalScope('goal-1'),
        'updated_at': '2026-11-10T09:30:00',
      },
      where: 'id = ?',
      whereArgs: [active],
    );
    final again = await memories.activeIdentities(DateTime.now());
    expect(again.single.content, '同一内容');
    expect(again.single.scope, memoryGoalScope('goal-1'));
    expect(again.single.kind, 'episodic');
  });

  test('范围由类别决定：情景记忆跟目标走，语义记忆保持全局', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);

    // `MemoryKind.followsContext` 是领域侧的判断，写入路径与界面都在用它：
    // 情景是发生过的一件事，写本次范围；语义与程序是全局的事实与做法。
    expect(MemoryKind.episodic.followsContext, isTrue);
    expect(MemoryKind.semantic.followsContext, isFalse);
    expect(MemoryKind.procedural.followsContext, isFalse);

    final memories = MemoryRepository(rig.db);
    await _seedMemory(
      rig,
      id: 'memory-episodic',
      kind: 'episodic',
      content: '放缩方向不确定',
      scope: memoryGoalScope('goal-3'),
    );
    await _seedMemory(
      rig,
      id: 'memory-semantic',
      kind: 'semantic',
      content: '喜欢先看例子',
    );
    final other = await memories.activeForContext(
      now: DateTime.now(),
      scope: memoryGoalScope('goal-4'),
    );
    expect(other.map((memory) => memory.content), ['喜欢先看例子']);
    final same = await memories.activeForContext(
      now: DateTime.now(),
      scope: memoryGoalScope('goal-3'),
    );
    expect(
      same.map((memory) => memory.content),
      containsAll(['放缩方向不确定', '喜欢先看例子']),
    );
  });

  test('超过写入上限的记忆经写入路径跳过，不落库', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final applied = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      memories: memories,
      drafts: [MemoryDraft(kind: MemoryKind.episodic, content: '长' * 201)],
      sourceKind: MemorySourceKind.message,
      sourceId: 'msg-1',
    );
    expect(applied.changes, isEmpty, reason: '写入上限还是 200 字');
    expect(applied.skipped.single.message, contains('200'));
    expect(await selectRows(rig.db, 'memory'), isEmpty);
  });
}
