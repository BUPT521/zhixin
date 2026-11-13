import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/memory_service.dart';
import 'package:zhixin/data/db/write_transactions.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/domain/models/memory.dart';

import '../support/test_db.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('修改记忆后回答检索使用新内容', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      transactions: WriteTransactions(rig.db),
    );

    final id = await memories.create(
      kind: MemoryKind.difficulty,
      content: '以为条件概率和独立性等价',
      sourceKind: 'user',
    );
    final memory = (await memories.byId(id))!;
    await service.save(memory, content: '条件概率不等于独立性，需要单独判断');

    final active = await memories.activeForContext(now: DateTime.now());
    expect(active.single.content, contains('不等于独立性'));

    // 内容没变时再保存一次，仍然只有这一条记忆，也不形成新提交。
    final head = await rig.engine.headId(rig.db.raw);
    final commitId = await service.save(
      (await memories.byId(id))!,
      content: '条件概率不等于独立性，需要单独判断',
    );
    expect(commitId, isNull);
    expect(await memories.list(), hasLength(1));
    expect(await rig.engine.headId(rig.db.raw), head);
  });

  test('修改记忆返回提交编号，撤销后恢复原内容与有效期', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      transactions: WriteTransactions(rig.db),
    );
    final id = await memories.create(
      kind: MemoryKind.difficulty,
      content: '旧内容',
      validUntil: DateTime(2026, 12, 1),
    );

    final commitId = await service.save(
      (await memories.byId(id))!,
      content: '新内容',
      validUntil: DateTime(2026, 12, 10),
    );
    expect(commitId, isNotNull);
    expect((await memories.byId(id))!.content, '新内容');

    final undone = await rig.revisions.undoCommit(commitId!);
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
      transactions: WriteTransactions(rig.db),
    );
    final id = await memories.create(
      kind: MemoryKind.progress,
      content: '第 8 题独立完成',
    );

    final commitId = await service.delete(id);
    expect(commitId, isNotNull);
    expect((await memories.byId(id))!.status, 'deleted');

    final undone = await rig.revisions.undoCommit(commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect((await memories.byId(id))!.status, 'active');
  });

  test('新增记忆返回提交编号，撤销后移除这一条', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final memories = MemoryRepository(rig.db);
    final service = MemoryService(
      memories,
      transactions: WriteTransactions(rig.db),
    );

    final commitId = await service.add(
      kind: MemoryKind.preference,
      content: '晚上学习',
    );
    expect(commitId, isNotNull);
    expect(await memories.list(includeInactive: true), hasLength(1));

    final undone = await rig.revisions.undoCommit(commitId!);
    expect(undone.applied, isTrue, reason: undone.message);
    expect(await memories.list(includeInactive: true), isEmpty);
  });
}
