import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

void main() {
  test('过期与停用的记忆不进入上下文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);
    final now = DateTime.now();

    await repo.create(
      kind: MemoryKind.constraint,
      content: '本周只有半小时',
      validUntil: now.subtract(const Duration(days: 1)),
    );
    await repo.create(kind: MemoryKind.preference, content: '晚上学习');
    final future = await repo.create(
      kind: MemoryKind.difficulty,
      content: '放缩方向不确定',
      validUntil: now.add(const Duration(days: 7)),
    );

    final context = await repo.activeForContext(now: now);
    expect(context.map((memory) => memory.content), contains('晚上学习'));
    expect(context.map((memory) => memory.content), contains('放缩方向不确定'));
    expect(context.map((memory) => memory.content), isNot(contains('本周只有半小时')));

    await repo.supersede(future);
    final after = await repo.activeForContext(now: now);
    expect(after.map((memory) => memory.content), isNot(contains('放缩方向不确定')));

    final all = await repo.list(includeInactive: true);
    expect(all, hasLength(3));
    expect(all.where((memory) => memory.status == 'superseded'), hasLength(1));
  });

  test('记忆不按更新时间只取最近二十条，约束优先进入上下文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);
    final now = DateTime.now();

    await repo.create(kind: MemoryKind.constraint, content: '这周晚上只有半小时');
    for (var index = 0; index < 45; index++) {
      await repo.create(kind: MemoryKind.progress, content: '进展 $index');
    }

    final context = await repo.activeForContext(now: now);
    expect(context, hasLength(40));
    expect(context.first.content, '这周晚上只有半小时');
    expect(context.map((memory) => memory.content), contains('进展 44'));
  });

  test('有范围的记忆只在同一范围进入上下文', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);
    final now = DateTime.now();

    await repo.create(kind: MemoryKind.preference, content: '晚上学习');
    await repo.create(
      kind: MemoryKind.difficulty,
      content: '放缩方向不确定',
      scope: memoryGoalScope(1),
    );
    await repo.create(
      kind: MemoryKind.progress,
      content: '能独立做极限题',
      scope: memoryGoalScope(2),
    );

    final second = await repo.activeForContext(
      now: now,
      scope: memoryGoalScope(2),
    );
    expect(second.map((memory) => memory.content), contains('晚上学习'));
    expect(second.map((memory) => memory.content), contains('能独立做极限题'));
    expect(second.map((memory) => memory.content), isNot(contains('放缩方向不确定')));

    final global = await repo.activeForContext(now: now);
    expect(global.map((memory) => memory.content), ['晚上学习']);
  });

  test('同一范围的困难只读这一范围的条目', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);

    await repo.create(
      kind: MemoryKind.difficulty,
      content: '放缩方向不确定',
      scope: memoryGoalScope(1),
    );
    await repo.create(
      kind: MemoryKind.difficulty,
      content: '另一个目标的困难',
      scope: memoryGoalScope(2),
    );
    await repo.create(kind: MemoryKind.difficulty, content: '没有范围的困难');
    await repo.create(
      kind: MemoryKind.progress,
      content: '同一目标下的进展',
      scope: memoryGoalScope(1),
    );

    final items = await repo.activeDifficulties(memoryGoalScope(1));

    expect(items.map((item) => item.content), ['放缩方向不确定']);
  });

  test('删除是软删除，恢复后重新可用', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db.rawDb);
    final id = await repo.create(
      kind: MemoryKind.progress,
      content: '第 8 题独立完成',
    );
    await repo.delete(id);
    expect(await repo.activeForContext(now: DateTime.now()), isEmpty);
    await repo.restore(id);
    expect(await repo.activeForContext(now: DateTime.now()), hasLength(1));
  });
}
