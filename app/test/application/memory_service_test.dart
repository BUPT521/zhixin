import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/application/memory_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/service_runtime.dart';
import '../support/test_db.dart';

MemoryService _service(TestRig rig) => MemoryService(
  MemoryRepository(rig.db),
  tasks: TaskRepository(rig.db),
  materials: MaterialRepository(rig.db),
  transactions: WriteTransactions(rig.db, revisions: rig.engine),
  runtime: testRuntime(live: rig.db.live),
);

void main() {
  test('修改记忆原地改写：内存里的类型跟库一致，撤销后回到旧内容', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = _service(rig);
    final id = await memories.create(
      kind: MemoryKind.episodic,
      content: '以为条件概率和独立性等价',
    );
    final memory = (await memories.byId(id))!;
    expect(memory.kind, MemoryKind.episodic, reason: '三分类读回来就是同一类');

    final result = await service.save(
      memory,
      kind: MemoryKind.semantic,
      content: '条件概率不等于独立性，需要单独判断',
    );
    expect(result.commitId, isNotNull);
    final saved = (await memories.byId(id))!;
    expect(saved.content, '条件概率不等于独立性，需要单独判断');
    expect(saved.kind, MemoryKind.semantic);
    expect(saved.scope, isNull);

    final undone = await rig.revisions.undoCommit(result.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    final restored = (await memories.byId(id))!;
    expect(restored.content, '以为条件概率和独立性等价');
    expect(restored.kind, MemoryKind.episodic);
    expect(await memories.list(), hasLength(1), reason: '修改不新增行');
  });

  test('新增的手写记忆按语义写库，线索拿不到时写空串', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = _service(rig);

    final result = await service.add(
      kind: MemoryKind.semantic,
      content: '每次先问我要推哪一步',
    );
    expect(result.commitId, isNotNull);
    final saved = (await memories.list()).single;
    expect(saved.kind, MemoryKind.semantic);
    expect(saved.searchTerms, '');
    expect(saved.sourceKind, MemorySourceKind.user);
  });

  test('确认保留只写 reviewed_at，撤销后回到原来的确认时间', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = _service(rig);
    final id = await memories.create(
      kind: MemoryKind.semantic,
      content: '晚上学习',
    );
    final before = (await memories.byId(id))!;

    final result = await service.keep(id);
    expect(result.commitId, isNotNull);
    final kept = (await memories.byId(id))!;
    expect(kept.reviewedAt, isNotNull);
    expect(kept.updatedAt, before.updatedAt, reason: '确认保留不改更新时间');

    final undone = await rig.revisions.undoCommit(result.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memories.byId(id))!.reviewedAt, isNull);
  });

  test('删除记忆返回提交编号，撤销后状态改回 active', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = _service(rig);
    final id = await memories.create(
      kind: MemoryKind.episodic,
      content: '第 8 题独立完成',
    );

    final result = await service.delete(id);
    expect(result.commitId, isNotNull);
    expect((await memories.byId(id))!.status, MemoryStatus.deleted);

    final undone = await rig.revisions.undoCommit(result.commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memories.byId(id))!.status, MemoryStatus.active);
  });

  test('订阅中的记忆页在删除之后重读一次', () async {
    final rig = await openTestRigWithUndoRules();
    addTearDown(rig.close);
    final service = _service(rig);
    await MemoryRepository(rig.db)
        .create(kind: MemoryKind.semantic, content: '晚上学习');
    final views = <MemoryPageView>[];
    final subscription = service.watchMemories().listen(views.add);
    addTearDown(subscription.cancel);

    await _settle();
    expect(views, hasLength(1), reason: '订阅之后先读一次');
    expect(views.single.memories.single.content, '晚上学习');

    await service.delete(views.last.memories.single.id);
    await _settle();
    expect(views, hasLength(2), reason: '删除之后重读一次');
    expect(views.last.memories.single.active, isFalse);
  });
}

/// 让通知、读取与回填排到队尾：这几步都是微任务与定时器。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));
