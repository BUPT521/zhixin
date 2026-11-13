import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/memory_proposal_service.dart';
import 'package:zhixin/application/memory_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

Future<
  (
    TestRig rig,
    int conversationId,
    int helpedId,
    int wrongId,
    int independentId,
    int unstatedId,
  )
>
_seed(TestRig rig) async {
  final tasks = TaskRepository(rig.db.rawDb);
  final materials = MaterialRepository(rig.db.rawDb);
  final conversations = ConversationRepository(rig.db.rawDb);
  final attempts = AttemptRepository(rig.db.rawDb);
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
    role: 'user',
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
  await rig.db.update(
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
  await rig.db.update(
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
  await rig.db.update(
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

  return (rig, conversation, helped.id, wrong.id, independent.id, unstated.id);
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('按 R2 区分提示下完成、独立完成与延迟后的独立表现', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final service = MemoryProposalService(
      attempts: AttemptRepository(rig.db.rawDb),
      conversations: ConversationRepository(rig.db.rawDb),
      memories: MemoryRepository(rig.db.rawDb),
      transactions: WriteTransactions(rig.db),
    );

    final outcome = await service.propose(seeded.$2);
    expect(outcome.proposals, hasLength(2));
    final difficulty = outcome.proposals.firstWhere(
      (proposal) => proposal.kind == MemoryKind.difficulty,
    );
    final progress = outcome.proposals.firstWhere(
      (proposal) => proposal.kind == MemoryKind.progress,
    );
    expect(difficulty.sourceId, seeded.$4);
    expect(difficulty.scope, memoryGoalScope(1));
    expect(difficulty.content, contains('记反'));
    expect(difficulty.conditionLabel, contains('提示'));
    expect(difficulty.basis, contains('自评有误'));
    expect(difficulty.basis, contains('应用内帮助 1 次'));

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
      (proposal) => proposal.kind == MemoryKind.progress,
    );
    final commitId = await service.accept(progress);
    expect(commitId, isNotNull);

    final written = await MemoryRepository(rig.db.rawDb)
        .list(includeInactive: true);
    final memory = written.singleWhere(
      (entry) => entry.sourceId == progress.sourceId,
    );
    expect(memory.sourceKind, 'attempt');
    expect(memory.kind, MemoryKind.progress);
    expect(memory.scope, memoryGoalScope(1));
    expect(memory.status, 'active');
    expect(memory.content, contains('独立完成'));

    // 再次确认同一条提案不再写入。
    expect(await service.accept(progress), isNull);
    expect(
      (await MemoryRepository(rig.db.rawDb).list(includeInactive: true)).length,
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
    expect(await memoryService.delete(memory.id), isNotNull);
    expect(
      (await MemoryRepository(rig.db.rawDb).byId(memory.id))!.status,
      'deleted',
    );
  });

  test('同一判断来自不同作答时合并成一条提案', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final tasks = TaskRepository(rig.db.rawDb);
    final conversations = ConversationRepository(rig.db.rawDb);
    final attempts = AttemptRepository(rig.db.rawDb);
    final goal = await tasks.createGoal(title: '概率论期末');
    final conversation = await conversations.create(sourceRef: '例 3-3');
    await conversations.setGoal(conversation, goal);
    await conversations.append(
      conversation,
      role: 'user',
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
      await rig.db.update(
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
      memories: MemoryRepository(rig.db.rawDb),
      transactions: WriteTransactions(rig.db),
    );
    final outcome = await service.propose(conversation);
    expect(outcome.proposals, hasLength(1));
    expect(outcome.skipped, isNotEmpty);
    expect(outcome.skipped.any((note) => note.contains('指向同一判断')), isTrue);
  });

  test('用户纠正或删除后，同一来源版本不再生成旧判断', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final seeded = await _seed(rig);
    final repositories = RepositorySet(rig);
    final service = repositories.proposals;
    final memoryService = repositories.memoryService;

    final first = await service.propose(seeded.$2);
    final difficulty = first.proposals.firstWhere(
      (proposal) => proposal.kind == MemoryKind.difficulty,
    );
    await service.accept(difficulty);
    final memory = (await MemoryRepository(
      rig.db.rawDb,
    ).list()).singleWhere((entry) => entry.sourceId == difficulty.sourceId);

    // 用户纠正内容：同一来源不再按旧内容重新生成提案。
    await memoryService.save(memory, content: '记分母与分子时先写定义再代入。');
    final afterCorrection = await service.propose(seeded.$2);
    expect(
      afterCorrection.proposals.any(
        (proposal) => proposal.sourceId == difficulty.sourceId,
      ),
      isFalse,
    );
    expect(afterCorrection.skipped, isNotEmpty);

    // 用户删除：旧判断同样不再出现。
    await memoryService.delete(memory.id);
    final afterDelete = await service.propose(seeded.$2);
    expect(
      afterDelete.proposals.any(
        (proposal) => proposal.sourceId == difficulty.sourceId,
      ),
      isFalse,
    );
  });
}

class RepositorySet {
  RepositorySet(this.rig);

  final TestRig rig;

  late final MemoryProposalService proposals = MemoryProposalService(
    attempts: AttemptRepository(rig.db.rawDb),
    conversations: ConversationRepository(rig.db.rawDb),
    memories: MemoryRepository(rig.db.rawDb),
    transactions: WriteTransactions(rig.db),
  );

  late final MemoryService memoryService = MemoryService(
    MemoryRepository(rig.db.rawDb),
    transactions: WriteTransactions(rig.db),
  );
}
