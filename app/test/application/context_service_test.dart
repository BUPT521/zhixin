import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/context_service.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/schedule_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/buddy_protocol.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('深夜的当天时间块只取自然日之内的安排', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final schedule = ScheduleRepository(db);
    final now = DateTime(2026, 11, 7, 23, 30);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: schedule,
      memories: MemoryRepository(db),
      conversations: ConversationRepository(db),
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );
    final item = await tasks.createItem(title: '复习');
    final today = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 22),
      end: DateTime(2026, 11, 7, 23),
    );
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 8, 0, 30),
      end: DateTime(2026, 11, 8, 1),
    );

    final context = await service.load();

    expect(context.todayBlocks.map((block) => block.block.id), [today]);
  });

  test('凌晨的当天时间块不取前一天的安排', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final schedule = ScheduleRepository(db);
    final now = DateTime(2026, 11, 7, 2);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: schedule,
      memories: MemoryRepository(db),
      conversations: ConversationRepository(db),
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );
    final item = await tasks.createItem(title: '复习');
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 6, 20),
      end: DateTime(2026, 11, 6, 21),
    );
    final today = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 10),
      end: DateTime(2026, 11, 7, 11),
    );

    final context = await service.load();

    expect(context.todayBlocks.map((block) => block.block.id), [today]);
  });

  test('回答上下文只做一次检索，材料页、较早讨论与作答一起取五条左右', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final attempts = AttemptRepository(db);
    final conversations = ConversationRepository(db);
    final materials = MaterialRepository(db);
    final now = DateTime(2026, 11, 7, 20);
    final policy = TimePolicy(clock: () => now);
    final evidence = EvidenceService(repository: EvidenceRepository(db));
    final service = ContextService(
      tasks: tasks,
      attempts: attempts,
      schedule: ScheduleRepository(db),
      memories: MemoryRepository(db),
      conversations: conversations,
      materials: materials,
      runtime: testRuntime(policy: () => policy),
      evidence: evidence,
    );
    final goal = await tasks.createGoal(title: '矩阵');

    for (var index = 0; index < 6; index++) {
      final conversation = await conversations.create(
        title: '矩阵讨论 $index',
        goalId: goal,
      );
      await conversations.append(
        conversation,
        role: 'user',
        content: '矩阵的第 $index 个问题',
      );
      final attempt = await attempts.ensureOpenAttempt(conversation);
      await attempts.submit(
        attempt.id,
        answer: '第 $index 次作答',
        isCorrect: true,
        independent: true,
      );
    }
    final material = await materials.create(title: '矩阵讲义', goalId: goal);
    for (var page = 1; page <= 6; page++) {
      await materials.addPage(
        materialId: material,
        pageNo: page,
        content: '第 $page 页讲矩阵的运算。',
      );
    }

    final context = await service.load(goalId: goal, query: '矩阵');

    expect(context.recentAttempts, hasLength(6));
    expect(
      context.materialHits.length +
          context.relatedRecords.length +
          context.evidence.length,
      lessThanOrEqualTo(maxContextEvidenceHits),
      reason: '同一次检索合起来是五条左右的摘录，不再按三张表各读一遍',
    );
    expect(
      context.materialHits.length + context.relatedRecords.length,
      greaterThan(0),
    );
  });

  test('同一道题答过多次时，每次尝试都进入当前讨论的最近作答', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final attempts = AttemptRepository(db);
    final conversations = ConversationRepository(db);
    final now = DateTime(2026, 11, 7, 20);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: attempts,
      schedule: ScheduleRepository(db),
      memories: MemoryRepository(db),
      conversations: conversations,
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );

    final id = await conversations.create(title: '同一道题', entryKind: 'text');
    await conversations.append(id, role: 'user', content: '求条件概率');
    for (var index = 0; index < 2; index++) {
      final attempt = await attempts.ensureOpenAttempt(id);
      await attempts.submit(
        attempt.id,
        answer: '第 ${index + 1} 次',
        isCorrect: index == 1,
        independent: index == 1,
        delayed: index == 1,
      );
    }

    final context = await service.load(
      mode: BuddyMode.chat,
      conversationId: id,
    );

    // 同一道题不按记录去重：独立性、帮助次数与延迟都记在各次尝试上。
    expect(context.recentAttempts, hasLength(2));
    expect(context.recentAttempts.map((entry) => entry.question.id).toSet(), {
      id,
    });
    expect(context.recentAttempts.map((entry) => entry.attempt.userAnswer), [
      '第 2 次',
      '第 1 次',
    ]);
  });

  test('最近作答按本次目标范围读取，其他目标的不进入上下文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final attempts = AttemptRepository(db);
    final conversations = ConversationRepository(db);
    final now = DateTime(2026, 11, 7, 20);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: attempts,
      schedule: ScheduleRepository(db),
      memories: MemoryRepository(db),
      conversations: conversations,
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );

    final goalA = await tasks.createGoal(title: '概率论');
    final goalB = await tasks.createGoal(title: '线性代数');
    Future<int> submit(int? goalId, String text) async {
      final id = await conversations.create(title: text, goalId: goalId);
      await conversations.append(id, role: 'user', content: text);
      final attempt = await attempts.ensureOpenAttempt(id);
      await attempts.submit(
        attempt.id,
        answer: '作答',
        isCorrect: true,
        independent: true,
      );
      return id;
    }

    final inGoal = await submit(goalA, '条件概率的题');
    final otherGoal = await submit(goalB, '矩阵相似的题');
    final unassigned = await submit(null, '独立的一道题');

    final context = await service.load(mode: BuddyMode.chat, goalId: goalA);
    final ids = {for (final entry in context.recentAttempts) entry.question.id};
    expect(ids, containsAll([inGoal, unassigned]));
    expect(ids, isNot(contains(otherGoal)));
  });

  test('无归属求助只读当前讨论，带入来源只对这一轮有效', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final attempts = AttemptRepository(db);
    final conversations = ConversationRepository(db);
    final materials = MaterialRepository(db);
    final now = DateTime(2026, 11, 7, 20);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: attempts,
      schedule: ScheduleRepository(db),
      memories: MemoryRepository(db),
      conversations: conversations,
      materials: materials,
      runtime: testRuntime(policy: () => policy),
      evidence: EvidenceService(repository: EvidenceRepository(db)),
    );

    Future<int> conversation(String title) async {
      final id = await conversations.create(title: title);
      await conversations.append(id, role: 'user', content: '条件概率和独立性有什么区别');
      final attempt = await attempts.ensureOpenAttempt(id);
      await attempts.submit(
        attempt.id,
        answer: '条件概率是给定条件下的概率。',
        isCorrect: true,
        independent: true,
      );
      return id;
    }

    final current = await conversation('当前讨论');
    final other = await conversation('另一条无归属讨论');
    final material = await materials.create(title: '概率论讲义');
    await materials.addPage(
      materialId: material,
      pageNo: 1,
      content: '条件概率 P(A|B)=P(AB)/P(B)。',
    );
    final otherMessage =
        (await db.query(
              'message',
              columns: ['id'],
              where: 'conversation_id = ?',
              whereArgs: [other],
              orderBy: 'id DESC',
              limit: 1,
            )).single['id']!
            as int;

    final onlyCurrent = await service.load(
      query: '条件概率',
      conversationId: current,
    );
    // 当前讨论本身通过历史消息带入，不重复列进“较早的相关记录”。
    expect(onlyCurrent.relatedRecords, isEmpty);
    expect(
      onlyCurrent.recentAttempts.map((entry) => entry.question.id).toSet(),
      {current},
      reason: '无归属求助只读当前记录与带入来源',
    );
    expect(onlyCurrent.materialHits, isEmpty);

    final brought = await service.load(
      query: '条件概率',
      conversationId: current,
      broughtIdentities: {'message:$otherMessage', 'material_page:$material:1'},
    );
    expect(
      brought.relatedRecords.map((record) => record.conversationId),
      contains(other),
    );
    expect(
      brought.materialHits.map((hit) => (hit.materialId, hit.pageNo)),
      contains((material, 1)),
    );

    // 下一轮没有带入时，只读当前记录。
    final nextTurn = await service.load(query: '条件概率', conversationId: current);
    expect(
      nextTurn.relatedRecords.map((record) => record.conversationId),
      isNot(contains(other)),
    );
    expect(nextTurn.materialHits, isEmpty);
  });
  test('两门课的同名概念互不串入回答范围', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final conversations = ConversationRepository(db);
    final now = DateTime(2026, 11, 7, 20);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: ScheduleRepository(db),
      memories: MemoryRepository(db),
      conversations: conversations,
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
      evidence: EvidenceService(repository: EvidenceRepository(db)),
    );
    final probability = await tasks.createGoal(title: '概率论期末');
    final linear = await tasks.createGoal(title: '线性代数作业');
    Future<int> record(int goalId, String text) async {
      final id = await conversations.create(goalId: goalId);
      await conversations.append(id, role: 'user', content: text);
      return id;
    }

    final probabilityRecord = await record(probability, '独立性在概率论里的含义');
    final probabilityPeer = await record(probability, '另一个概率论记录');
    await conversations.append(
      probabilityPeer,
      role: 'user',
      content: '独立性在概率论里的另一处说明',
    );
    final linearRecord = await record(linear, '独立性在向量组里的含义');

    final context = await service.load(
      goalId: probability,
      query: '独立性',
      conversationId: probabilityRecord,
    );
    final seen = context.relatedRecords
        .map((record) => record.conversationId)
        .toSet();
    expect(seen, contains(probabilityPeer));
    expect(seen, isNot(contains(linearRecord)));
  });

  test('首页活动卡不把次日凌晨的安排当成今天', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final schedule = ScheduleRepository(db);
    final now = DateTime(2026, 11, 7, 23, 30);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: schedule,
      memories: MemoryRepository(db),
      conversations: ConversationRepository(db),
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );
    final item = await tasks.createItem(title: '复习');
    await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 8, 0, 10),
      end: DateTime(2026, 11, 8, 0, 40),
    );

    final activity = await service.loadActivity();

    expect(activity.ongoing, isNull);
    expect(activity.next, isNull);
    expect(activity.pending!.title, '复习');
  });

  test('首页活动卡把晚些时候的预约放在接下来', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final schedule = ScheduleRepository(db);
    final now = DateTime(2026, 11, 7, 9);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: schedule,
      memories: MemoryRepository(db),
      conversations: ConversationRepository(db),
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );
    final item = await tasks.createItem(title: '晚间复习');
    final block = await schedule.addBlock(
      planItemId: item,
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 20),
    );

    final activity = await service.loadActivity();

    expect(activity.ongoing, isNull);
    expect(activity.next!.scheduled.block.id, block);
    expect(activity.next!.item.title, '晚间复习');
    expect(activity.pending, isNull);
  });

  test('首页活动卡分开正在进行与接下来', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final schedule = ScheduleRepository(db);
    final now = DateTime(2026, 11, 7, 9);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: schedule,
      memories: MemoryRepository(db),
      conversations: ConversationRepository(db),
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );
    final doingItem = await tasks.createItem(title: '正在复习');
    final doingBlock = await schedule.addBlock(
      planItemId: doingItem,
      start: DateTime(2026, 11, 7, 8, 30),
      end: DateTime(2026, 11, 7, 9, 30),
    );
    final laterItem = await tasks.createItem(title: '晚间复习');
    final laterBlock = await schedule.addBlock(
      planItemId: laterItem,
      start: DateTime(2026, 11, 7, 19),
      end: DateTime(2026, 11, 7, 20),
    );

    final activity = await service.loadActivity();

    expect(activity.ongoing!.scheduled.block.id, doingBlock);
    expect(activity.ongoing!.item.title, '正在复习');
    expect(activity.next!.scheduled.block.id, laterBlock);
    expect(activity.next!.item.title, '晚间复习');
  });

  test('首页活动卡在没有预约时给出待开始事项', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final tasks = TaskRepository(db);
    final now = DateTime(2026, 11, 7, 9);
    final policy = TimePolicy(clock: () => now);
    final service = ContextService(
      tasks: tasks,
      attempts: AttemptRepository(db),
      schedule: ScheduleRepository(db),
      memories: MemoryRepository(db),
      conversations: ConversationRepository(db),
      materials: MaterialRepository(db),
      runtime: testRuntime(policy: () => policy),
    );
    await tasks.createItem(title: '整理笔记', estMinutes: 25);

    final activity = await service.loadActivity();

    expect(activity.ongoing, isNull);
    expect(activity.next, isNull);
    expect(activity.pending!.title, '整理笔记');
    expect(activity.pending!.estMinutes, 25);
  });
}
