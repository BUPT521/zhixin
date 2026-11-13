import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/application/buddy_actions.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

void main() {
  test('模型给的记忆落库，并留下可按提交撤销的回执', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db.rawDb);

    const draft = MemoryDraft(
      kind: MemoryKind.constraint,
      content: '本周晚上只有半小时',
    );
    final result = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: const [draft],
      sourceKind: 'message',
      sourceId: 1,
    );
    expect(result.changes, hasLength(1));
    expect(result.changes.single.draft, same(draft));
    expect(await memories.activeForContext(now: DateTime.now()), hasLength(1));

    final commitId = result.changes.single.commitId;
    expect(await rig.revisions.activeCommits([commitId]), {commitId});
    final undone = await rig.revisions.undoCommit(commitId);
    expect(undone.applied, isTrue);
    expect(await memories.activeForContext(now: DateTime.now()), isEmpty);
    expect(await rig.revisions.activeCommits([commitId]), isEmpty);
  });

  test('用户修改记忆后，旧的写入提交不能删除新内容', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db.rawDb);
    final id = await memories.create(
      kind: MemoryKind.difficulty,
      content: '原有困难',
      sourceKind: 'message',
    );
    final created = (await rig.engine.undoableCommits(rig.db.raw)).last;
    await memories.updateContent(id, content: '用户修改后的困难');

    final undone = await rig.revisions.undoCommit(created.id);
    expect(undone.applied, isFalse);
    expect(undone.message, '这次操作之后，同一项内容又被修改过，不能撤销');
    expect((await memories.byId(id))!.content, '用户修改后的困难');
    expect(await rig.revisions.activeCommits([created.id]), {created.id});
  });

  test('已接受的事项有后续预约时，撤销创建不会级联删除预约', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final schedule = ScheduleRepository(rig.db.rawDb);
    final tasks = TaskRepository(rig.db.rawDb);
    final itemId = await tasks.createItem(title: '复习题目');
    final created = (await rig.engine.undoableCommits(rig.db.raw)).last;
    final start = DateTime(2026, 11, 8, 10);
    final blockId = await schedule.addBlock(
      planItemId: itemId,
      start: start,
      end: start.add(const Duration(minutes: 30)),
    );

    final undone = await rig.revisions.undoCommit(created.id);
    expect(undone.applied, isFalse);
    expect(undone.message, '这项任务已有预约，不能撤销');
    expect(
      await rig.db.query('plan_item', where: 'id = ?', whereArgs: [itemId]),
      hasLength(1),
    );
    expect(await schedule.blockById(blockId), isNotNull);
    expect(await rig.revisions.activeCommits([created.id]), {created.id});
  });

  test('重复的记忆不重复写，过长的记忆被跳过', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db.rawDb);

    await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: const [
        MemoryDraft(kind: MemoryKind.preference, content: '喜欢先看例子'),
      ],
      sourceKind: 'message',
    );
    final second = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: [
        const MemoryDraft(kind: MemoryKind.preference, content: '喜欢先看例子'),
        MemoryDraft(kind: MemoryKind.difficulty, content: '长' * 201),
      ],
      sourceKind: 'message',
    );
    expect(second.changes, isEmpty);
    expect(second.skipped, isNotEmpty);
    expect(await memories.activeForContext(now: DateTime.now()), hasLength(1));
  });

  test('记忆去重区分类别与范围，过期记录和本批重复项不误抑制', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db.rawDb);
    await memories.create(
      kind: MemoryKind.difficulty,
      content: '同一内容',
      scope: 'goal:1',
      validUntil: DateTime.now().subtract(const Duration(days: 1)),
    );

    final first = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: const [
        MemoryDraft(kind: MemoryKind.difficulty, content: '同一内容'),
        MemoryDraft(kind: MemoryKind.difficulty, content: '同一内容'),
      ],
      sourceKind: 'message',
      scope: 'goal:1',
    );
    final otherScope = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: const [MemoryDraft(kind: MemoryKind.difficulty, content: '同一内容')],
      sourceKind: 'message',
      scope: 'goal:2',
    );
    final otherKind = await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: const [MemoryDraft(kind: MemoryKind.preference, content: '同一内容')],
      sourceKind: 'message',
      scope: 'goal:1',
    );

    expect(first.changes, hasLength(1));
    expect(otherScope.changes, hasLength(1));
    expect(otherKind.changes, hasLength(1));
    expect(await rig.db.query('memory'), hasLength(4));
    expect(await rig.engine.undoableCommits(rig.db.raw), hasLength(4));
  });

  test('困难与进展写入本次范围，偏好与限制保持全局', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db.rawDb);

    await applyMemoryDrafts(
      transactions: WriteTransactions(rig.db),
      memories: memories,
      drafts: const [
        MemoryDraft(kind: MemoryKind.difficulty, content: '放缩方向不确定'),
        MemoryDraft(kind: MemoryKind.progress, content: '能独立列出条件'),
        MemoryDraft(kind: MemoryKind.preference, content: '喜欢先看例子'),
        MemoryDraft(kind: MemoryKind.constraint, content: '晚上只有半小时'),
      ],
      sourceKind: 'message',
      scope: memoryGoalScope(3),
    );
    final all = await memories.list();
    expect(all, hasLength(4));
    String? scopeOf(String content) =>
        all.firstWhere((memory) => memory.content == content).scope;
    expect(scopeOf('放缩方向不确定'), memoryGoalScope(3));
    expect(scopeOf('能独立列出条件'), memoryGoalScope(3));
    expect(scopeOf('喜欢先看例子'), isNull);
    expect(scopeOf('晚上只有半小时'), isNull);

    final other = await memories.activeForContext(
      now: DateTime.now(),
      scope: memoryGoalScope(4),
    );
    expect(
      other.map((memory) => memory.content),
      unorderedEquals(['喜欢先看例子', '晚上只有半小时']),
    );
  });
}
