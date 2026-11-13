import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/application/memory_recall.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('规划、讲解与检查按用途取不同类别的记忆，约束始终先占预算', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var minute = 0;
    final repo = MemoryRepository(
      db.rawDb,
      clock: () => DateTime(2026, 11, 12, 9, minute++),
    );
    final now = DateTime(2026, 11, 12, 10);
    await repo.create(kind: MemoryKind.constraint, content: '这周晚上只有半小时');
    await repo.create(kind: MemoryKind.preference, content: '讲解时先给一个例子');
    await repo.create(kind: MemoryKind.difficulty, content: '放缩方向不确定');
    await repo.create(kind: MemoryKind.progress, content: '第 8 题独立完成');
    final recall = MemoryRecallService(repo);

    final plan = await recall.recall(
      now: now,
      purpose: MemoryRecallPurpose.plan,
    );
    expect(plan.first.content, '这周晚上只有半小时');
    expect(plan.map((memory) => memory.content).toList(), [
      '这周晚上只有半小时',
      '讲解时先给一个例子',
      '第 8 题独立完成',
      '放缩方向不确定',
    ]);

    final explain = await recall.recall(
      now: now,
      purpose: MemoryRecallPurpose.explain,
    );
    expect(explain.first.content, '这周晚上只有半小时');
    expect(
      explain.take(3).map((memory) => memory.content),
      isNot(contains('第 8 题独立完成')),
      reason: '讲解优先取偏好与本题困难，进展排在后面',
    );

    final check = await recall.recall(
      now: now,
      purpose: MemoryRecallPurpose.check,
    );
    expect(check.first.content, '这周晚上只有半小时');
    expect(check[1].content, '第 8 题独立完成');
  });

  test('旧记忆比新记忆更相关时排在前面', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(
      db.rawDb,
      clock: () => DateTime(2026, 11, 12, 9),
    );
    await repo.create(
      kind: MemoryKind.progress,
      content: '条件概率与独立性可以一起判断：P(AB)=P(A)P(B)。',
    );
    await db.update(
      'memory',
      {'updated_at': '2026-10-01 09:00:00'},
      where: 'kind = ?',
      whereArgs: [MemoryKind.progress.value],
    );
    await repo.create(kind: MemoryKind.progress, content: '今天状态一般，先做简单题。');

    final recall = MemoryRecallService(repo);
    final results = await recall.recall(
      now: DateTime(2026, 11, 12, 10),
      purpose: MemoryRecallPurpose.check,
      query: '条件概率 独立性',
    );
    expect(results.first.content, contains('条件概率与独立性'));
  });

  test('过期、删除、替代与其他范围的记忆不进入召回', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);
    final now = DateTime(2026, 11, 12, 10);
    await repo.create(kind: MemoryKind.preference, content: '晚上学习');
    await repo.create(
      kind: MemoryKind.preference,
      content: '这周先只看第一章',
      validUntil: now.subtract(const Duration(days: 1)),
    );
    final deleted = await repo.create(
      kind: MemoryKind.progress,
      content: '暂时不再用这条',
    );
    await repo.delete(deleted);
    final replaced = await repo.create(
      kind: MemoryKind.difficulty,
      content: '旧的卡点',
    );
    await repo.supersede(replaced);
    await repo.create(
      kind: MemoryKind.difficulty,
      content: '另一个目标的卡点',
      scope: memoryGoalScope(2),
    );

    final results = await MemoryRecallService(repo).recall(
      now: now,
      purpose: MemoryRecallPurpose.chat,
      scope: memoryGoalScope(1),
    );
    expect(results.map((memory) => memory.content), ['晚上学习']);
  });

  test('最多 40 条，单条进入提示词时截到 200 字', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);
    final now = DateTime(2026, 11, 12, 10);
    await repo.create(kind: MemoryKind.constraint, content: '这周晚上只有半小时');
    for (var index = 0; index < 45; index++) {
      await repo.create(kind: MemoryKind.progress, content: '进展 $index');
    }
    final long = await repo.create(
      kind: MemoryKind.preference,
      content: '讲' * 300,
    );

    final results = await MemoryRecallService(repo)
        .recall(now: now, purpose: MemoryRecallPurpose.plan);
    expect(results, hasLength(40));
    expect(results.first.content, '这周晚上只有半小时');

    final memory = (await repo.byId(long))!;
    final prompt = buildBuddySystemPrompt(
      BuddyContext(now: now, memories: [memory]),
    );
    expect(prompt, contains('讲' * 200));
    expect(prompt, isNot(contains('讲' * 201)));
    expect(prompt, contains('用户本轮说明优先于下面记住的旧偏好'));
  });

  test('检查优先取带来源的近期进展', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    var minute = 0;
    final repo = MemoryRepository(
      db.rawDb,
      clock: () => DateTime(2026, 11, 12, 9, minute++),
    );
    final now = DateTime(2026, 11, 12, 10);
    await repo.create(
      kind: MemoryKind.progress,
      content: '来自作答的进展：第 8 题独立完成',
      sourceKind: 'attempt',
      sourceId: 7,
    );
    await repo.create(kind: MemoryKind.progress, content: '手工写下的进展');

    final results = await MemoryRecallService(repo)
        .recall(now: now, purpose: MemoryRecallPurpose.check);
    expect(results, hasLength(2));
    expect(results.first.content, contains('第 8 题独立完成'));
    expect(results.last.sourceKind, 'user');
  });
}
