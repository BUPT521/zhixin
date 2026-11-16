import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/memory_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

void main() {
  test('修改记忆后回答检索使用新内容', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      tasks: TaskRepository(rig.db),
      materials: MaterialRepository(rig.db),
      transactions: WriteTransactions(rig.db),
      runtime: testRuntime(),
    );

    final id = await memories.create(
      kind: MemoryKind.difficulty,
      content: '以为条件概率和独立性等价',
      sourceKind: MemorySourceKind.user,
    );
    final memory = (await memories.byId(id))!;
    await service.save(memory, content: '条件概率不等于独立性，需要单独判断');

    final active = await memories.activeForContext(now: DateTime.now());
    expect(active.single.content, contains('不等于独立性'));

    // 内容没变时再保存一次，仍然只有这一条记忆，也不形成新提交。
    final head = await rig.engine.headId(rig.db.raw);
    final result = await service.save(
      (await memories.byId(id))!,
      content: '条件概率不等于独立性，需要单独判断',
    );
    expect(result.changed, isFalse);
    expect(result.skippedReason, isNotNull);
    expect(await memories.list(), hasLength(1));
    expect(await rig.engine.headId(rig.db.raw), head);
  });

  test('修改记忆返回提交编号，撤销后恢复原内容与有效期', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      tasks: TaskRepository(rig.db),
      materials: MaterialRepository(rig.db),
      transactions: WriteTransactions(rig.db),
      runtime: testRuntime(),
    );
    final id = await memories.create(
      kind: MemoryKind.difficulty,
      content: '旧内容',
      validUntil: DateTime(2026, 12, 1),
    );

    final result = await service.save(
      (await memories.byId(id))!,
      content: '新内容',
      validUntil: DateTime(2026, 12, 10),
    );
    expect(result.commitId, isNotNull);
    expect((await memories.byId(id))!.content, '新内容');

    final undone = await rig.revisions.undoCommit(result.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    final restored = (await memories.byId(id))!;
    expect(restored.content, '旧内容');
    expect(restored.validUntil, DateTime(2026, 12, 1));
  });

  test('删除记忆返回提交编号，撤销后状态改回 active', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      tasks: TaskRepository(rig.db),
      materials: MaterialRepository(rig.db),
      transactions: WriteTransactions(rig.db),
      runtime: testRuntime(),
    );
    final id = await memories.create(
      kind: MemoryKind.progress,
      content: '第 8 题独立完成',
    );

    final result = await service.delete(id);
    expect(result.commitId, isNotNull);
    expect((await memories.byId(id))!.status, MemoryStatus.deleted);

    final undone = await rig.revisions.undoCommit(result.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memories.byId(id))!.status, MemoryStatus.active);
  });

  test('新增记忆返回提交编号，撤销后移除这一条', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      tasks: TaskRepository(rig.db),
      materials: MaterialRepository(rig.db),
      transactions: WriteTransactions(rig.db),
      runtime: testRuntime(),
    );

    final result = await service.add(
      kind: MemoryKind.preference,
      content: '晚上学习',
    );
    expect(result.commitId, isNotNull);
    expect(await memories.list(includeInactive: true), hasLength(1));

    final undone = await rig.revisions.undoCommit(result.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await memories.list(includeInactive: true), isEmpty);
  });

  test('订阅中的记忆页在保存与删除之后重读一次', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      tasks: TaskRepository(rig.db),
      materials: MaterialRepository(rig.db),
      transactions: WriteTransactions(rig.db),
      runtime: testRuntime(live: rig.db.live),
    );
    final views = <MemoryPageView>[];
    final subscription = service.watchMemories().listen(views.add);
    addTearDown(subscription.cancel);

    await _settle();
    expect(views, hasLength(1), reason: '订阅之后先读一次');
    expect(views.single.memories, isEmpty);

    await service.add(kind: MemoryKind.preference, content: '晚上学习');
    await _settle();
    expect(views, hasLength(2), reason: '写入之后重读一次');
    expect(views.last.memories.single.content, '晚上学习');

    await service.delete(views.last.memories.single.id);
    await _settle();
    expect(views, hasLength(3), reason: '删除之后重读一次');
    expect(views.last.memories.single.active, isFalse);
  });
}

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
