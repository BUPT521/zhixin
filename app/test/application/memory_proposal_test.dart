import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/memory_proposal_service.dart';
import 'package:zhixin/application/memory_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

import 'package:zhixin/data/db/sql.dart';

Future<
  (
    TestRig rig,
    String conversationId,
    String helpedId,
    String wrongId,
    String independentId,
    String unstatedId,
    String goalId,
  )
>
_seed(TestRig rig) async {
  final tasks = TaskRepository(rig.db);
  final materials = MaterialRepository(rig.db);
  final conversations = ConversationRepository(rig.db);
  final attempts = AttemptRepository(rig.db);
  final goal = await tasks.createGoal(title: '概率论期末');
  final material = await materials.create(title: '概率论讲义', goalId: goal);
  await materials.addPage(
    materialId: material,
    pageNo: 7,
    content: '例 3-2 求条件概率 P(A|B)。',
  );
  final conversation = await conversations.create(sourceRef: '例 3-2');
  await conversations.setGoal(conversation, goal);
  await conversations.setMaterial(
    conversation,
    materialId: material,
    pageNo: 7,
  );
  await conversations.append(
    conversation,
    role: MessageRole.user,
    content: '例 3-2 求条件概率 P(A|B)',
  );

  final helped = await attempts.ensureOpenAttempt(conversation);
  await attempts.submit(
    helped.id,
    answer: 'P(AB)/P(B)',
    isCorrect: true,
    independent: false,
    feedback: '看过提示才写对。',
  );
  await updateRow(
    rig.db,
    'attempt',
    {
      'help_json': jsonEncode([
        {
          'kind': 'hint',
          'content': '先想 P(AB) 与 P(B) 的关系。',
          'at': '2026-10-01 09:10:00',
        },
      ]),
      'submitted_at': '2026-10-01 09:20:00',
    },
    where: 'id = ?',
    whereArgs: [helped.id],
  );

  final wrong = await attempts.ensureOpenAttempt(conversation);
  await attempts.submit(
    wrong.id,
    answer: '记反了，写成 P(B)/P(AB)。',
    isCorrect: false,
    independent: false,
    feedback: '把分子分母记反了。',
  );
  await updateRow(
    rig.db,
    'attempt',
    {
      'help_json': jsonEncode([
        {'kind': 'explain', 'content': '条件概率的定义。', 'at': '2026-10-02 21:10:00'},
      ]),
      'submitted_at': '2026-10-02 21:20:00',
    },
    where: 'id = ?',
    whereArgs: [wrong.id],
  );

  final independent = await attempts.ensureOpenAttempt(
    conversation,
    redoOfAttemptId: helped.id,
    delayed: true,
  );
  await attempts.submit(
    independent.id,
    answer: 'P(A|B)=P(AB)/P(B)',
    isCorrect: true,
    independent: true,
    delayed: true,
  );
  await updateRow(
    rig.db,
    'attempt',
    {'submitted_at': '2026-10-03 20:00:00'},
    where: 'id = ?',
    whereArgs: [independent.id],
  );

  final unstated = await attempts.ensureOpenAttempt(conversation);
  await attempts.submit(
    unstated.id,
    answer: 'P(AB)/P(B)',
    isCorrect: true,
    independent: null,
  );

  return (
    rig,
    conversation,
    helped.id,
    wrong.id,
    independent.id,
    unstated.id,
    goal,
  );
}

void main() {
  test('按 R2 区分提示下完成、独立完成与延迟后的独立表现', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final service = MemoryProposalService(
      attempts: AttemptRepository(rig.db),
      conversations: ConversationRepository(rig.db),
      memories: MemoryRepository(rig.db),
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      runtime: testRuntime(),
    );

    final outcome = await service.propose(seeded.$2);
    expect(outcome.proposals, hasLength(2));
    // 困难与进展现在都是情景标签，按来源作答的结果区分：`isDifficulty` 由程序
    // 按作答本身判断，不再写在类别里（ADR-0051 决定第 9 条）。
    final difficulty = outcome.proposals.firstWhere(
      (proposal) => proposal.isDifficulty,
    );
    final progress = outcome.proposals.firstWhere(
      (proposal) => !proposal.isDifficulty,
    );
    expect(difficulty.kind, MemoryKind.episodic);
    expect(progress.kind, MemoryKind.episodic);
    expect(difficulty.sourceId, seeded.$4);
    expect(difficulty.scope, memoryGoalScope(seeded.$7));
    expect(difficulty.content, contains('记反'));
    expect(difficulty.conditionLabel, contains('提示'));
    expect(difficulty.basis, contains('自评有误'));
    expect(difficulty.basis, contains('应用内帮助 1 次'));
    expect(difficulty.removesDifficultyId, isNull, reason: '困难提案不删旧困难');

    expect(progress.sourceId, seeded.$5);
    expect(progress.conditionLabel, '隔一段时间后独立完成');
    expect(progress.content, contains('独立完成'));
    expect(progress.basis, contains('间隔后重做'));

    // 在帮助下做对、独立性未说明都没有写成独立完成。
    expect(outcome.notes.any((note) => note.contains('不记为独立表现')), isTrue);
    expect(outcome.notes.any((note) => note.contains('没有说明是否独立')), isTrue);
    expect(
      outcome.proposals.any((proposal) => proposal.sourceId == seeded.$3),
      isFalse,
    );
  });

  test('确认提案写入带来源与范围的记忆，重复确认只产生一次变更', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final repositories = RepositorySet(rig);
    final service = repositories.proposals;
    final memoryService = repositories.memoryService;

    final outcome = await service.propose(seeded.$2);
    final progress = outcome.proposals.firstWhere(
      (proposal) => !proposal.isDifficulty,
    );
    final acceptResult = await service.accept(progress);
    expect(acceptResult.commitId, isNotNull);

    final written = await MemoryRepository(rig.db).list(includeInactive: true);
    final memory = written.singleWhere(
      (entry) => entry.sourceId == progress.sourceId,
    );
    expect(memory.sourceKind, MemorySourceKind.attempt);
    expect(memory.kind, MemoryKind.episodic);
    expect(memory.scope, memoryGoalScope(seeded.$7));
    expect(memory.status, MemoryStatus.active);
    expect(memory.content, contains('独立完成'));

    // 再次确认同一条提案不再写入。
    expect((await service.accept(progress)).changed, isFalse);
    expect(
      (await MemoryRepository(rig.db).list(includeInactive: true)).length,
      written.length,
    );

    // 重复提取只跳过已经处理过的来源。
    final again = await service.propose(seeded.$2);
    expect(
      again.proposals.any((proposal) => proposal.sourceId == progress.sourceId),
      isFalse,
    );
    expect(again.skipped, isNotEmpty);

    // 记忆页仍可用既有入口纠正与删除；这里验证入口存在且能改变状态。
    expect((await memoryService.delete(memory.id)).commitId, isNotNull);
    expect(
      (await MemoryRepository(rig.db).byId(memory.id))!.status,
      MemoryStatus.deleted,
    );
  });

  test('进展提案带走旧困难：接受时写入与删除在同一条提交里', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final memories = MemoryRepository(rig.db);
    final service = MemoryProposalService(
      attempts: AttemptRepository(rig.db),
      conversations: ConversationRepository(rig.db),
      memories: memories,
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      runtime: testRuntime(),
    );

    final first = await service.propose(seeded.$2);
    final difficulty = first.proposals.firstWhere(
      (proposal) => proposal.isDifficulty,
    );
    // 困难提案已经写入：同一道题、同一范围里的一条情景记忆，来源指回作答。
    final difficultyId = await memories.create(
      kind: MemoryKind.episodic,
      content: difficulty.content,
      scope: difficulty.scope,
      sourceKind: MemorySourceKind.attempt,
      sourceId: difficulty.sourceId,
    );

    // 再提取一次：进展提案带上那条旧困难，默认勾选的“同时删除旧的困难”。
    final second = await service.propose(seeded.$2);
    final progress = second.proposals.firstWhere(
      (proposal) => !proposal.isDifficulty,
    );
    expect(progress.removesDifficultyId, difficultyId);
    expect(progress.removesDifficultyContent, difficulty.content);

    final accepted = await service.accept(progress);
    expect(accepted.commitId, isNotNull);
    expect((await memories.byId(difficultyId))!.status, MemoryStatus.deleted);
    final written = await memories.list();
    expect(written.single.content, progress.content);
    expect(written.single.kind, MemoryKind.episodic);

    // 写入与删除在同一条提交里：撤销这一次就一起撤回。
    final undone = await rig.revisions.undoCommit(accepted.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memories.byId(difficultyId))!.status, MemoryStatus.active);
    expect((await memories.list()).single.id, difficultyId);

    // 用户选择保留旧困难时，只写进展，不删旧困难。
    final third = await service.propose(seeded.$2);
    final again = third.proposals.firstWhere(
      (proposal) => !proposal.isDifficulty,
    );
    await service.accept(again, removeDifficulty: false);
    expect((await memories.byId(difficultyId))!.status, MemoryStatus.active);
  });
  test('同一判断来自不同作答时合并成一条提案', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db);
    final conversations = ConversationRepository(rig.db);
    final attempts = AttemptRepository(rig.db);
    final goal = await tasks.createGoal(title: '概率论期末');
    final conversation = await conversations.create(sourceRef: '例 3-3');
    await conversations.setGoal(conversation, goal);
    await conversations.append(
      conversation,
      role: MessageRole.user,
      content: '例 3-3 求期望',
    );

    for (var index = 0; index < 2; index++) {
      final attempt = await attempts.ensureOpenAttempt(conversation);
      await attempts.submit(
        attempt.id,
        answer: '漏乘概率。',
        isCorrect: false,
        independent: false,
        feedback: '总是漏乘概率。',
      );
      await updateRow(
        rig.db,
        'attempt',
        {
          'submitted_at': '2026-10-0${index + 1} 20:00:00',
          'help_json':
              '[{"kind":"hint","content":"先列分布","at":"2026-10-01 20:00:00"}]',
        },
        where: 'id = ?',
        whereArgs: [attempt.id],
      );
    }

    final service = MemoryProposalService(
      attempts: attempts,
      conversations: conversations,
      memories: MemoryRepository(rig.db),
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      runtime: testRuntime(),
    );
    final outcome = await service.propose(conversation);
    expect(outcome.proposals, hasLength(1));
    expect(outcome.skipped, isNotEmpty);
    expect(outcome.skipped.any((note) => note.contains('指向同一判断')), isTrue);
  });

  test('用户删掉某条来源的记忆之后，同一来源不再生成旧判断', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final repositories = RepositorySet(rig);
    final service = repositories.proposals;
    final memoryService = repositories.memoryService;

    final first = await service.propose(seeded.$2);
    final difficulty = first.proposals.firstWhere(
      (proposal) => proposal.isDifficulty,
    );
    // 困难按情景标签写进库；这一行带着同一来源，来源因此算处理过。删除是改
    // 状态，之后同一来源仍然算处理过。
    await MemoryRepository(rig.db).create(
      id: 'memory-difficulty',
      kind: MemoryKind.episodic,
      content: '例 3-3：在「记反」处卡住。',
      scope: memoryGoalScope(seeded.$7),
      sourceKind: MemorySourceKind.attempt,
      sourceId: difficulty.sourceId,
    );
    final afterWrite = await service.propose(seeded.$2);
    expect(
      afterWrite.proposals.any(
        (proposal) => proposal.sourceId == difficulty.sourceId,
      ),
      isFalse,
    );
    expect(afterWrite.skipped, isNotEmpty);

    // 用户删除：旧判断同样不再出现。
    await memoryService.delete('memory-difficulty');
    final afterDelete = await service.propose(seeded.$2);
    expect(
      afterDelete.proposals.any(
        (proposal) => proposal.sourceId == difficulty.sourceId,
      ),
      isFalse,
    );
    expect(
      (await MemoryRepository(rig.db).byId('memory-difficulty'))!.status,
      MemoryStatus.deleted,
    );
  });

  test('订阅中的记录列表在建议写入之后重读一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final service = MemoryProposalService(
      attempts: AttemptRepository(rig.db),
      conversations: ConversationRepository(rig.db),
      memories: MemoryRepository(rig.db),
      transactions: WriteTransactions(rig.db, revisions: rig.engine),
      runtime: testRuntime(live: rig.db.live),
    );
    final counts = <int>[];
    final subscription = service.watchQuestions().listen(
      (rows) => counts.add(rows.length),
    );
    addTearDown(subscription.cancel);

    await _settle();
    expect(counts, hasLength(1), reason: '订阅之后先读一次');
    expect(counts.single, 1, reason: '种子数据只有一条有作答的记录');

    final outcome = await service.propose(seeded.$2);
    await service.accept(outcome.proposals.first);
    await _settle();
    expect(counts, hasLength(2), reason: '写入记忆之后重读一次');
    expect(counts.last, 1);
  });
}

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

class RepositorySet {
  RepositorySet(this.rig);

  final TestRig rig;

  late final MemoryProposalService proposals = MemoryProposalService(
    attempts: AttemptRepository(rig.db),
    conversations: ConversationRepository(rig.db),
    memories: MemoryRepository(rig.db),
    transactions: WriteTransactions(rig.db, revisions: rig.engine),
    runtime: testRuntime(),
  );

  late final MemoryService memoryService = MemoryService(
    MemoryRepository(rig.db),
    tasks: TaskRepository(rig.db),
    materials: MaterialRepository(rig.db),
    transactions: WriteTransactions(rig.db, revisions: rig.engine),
    runtime: testRuntime(),
  );
}
