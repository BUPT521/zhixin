import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/data/db/sql.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/test_db.dart';

/// 依次给出时刻的时钟：写入时间、修改时间与确认保留时间由用例决定。
Clock _clockAt(Iterable<DateTime> times) {
  final list = times.toList(growable: false);
  var index = 0;
  return () => list[index < list.length - 1 ? index++ : list.length - 1];
}

Future<Map<String, Object?>> _row(TestRig rig, String id) async =>
    (await selectRows(
      rig.db,
      'memory',
      where: 'id = ?',
      whereArgs: [id],
    )).single;

void main() {
  test('三类标签都能建库并读回，旧四类标签读出来按映射归到三类', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);

    final ids = <MemoryKind, String>{};
    for (final kind in [
      MemoryKind.episodic,
      MemoryKind.semantic,
      MemoryKind.procedural,
    ]) {
      ids[kind] = await repo.create(
        kind: kind,
        content: '${kind.label}的一条',
        searchTerms: '${kind.label} 线索',
      );
    }
    final stored = await repo.list();
    expect(stored, hasLength(3));
    for (final entry in ids.entries) {
      final memory = stored.singleWhere((memory) => memory.id == entry.value);
      expect(memory.kind, entry.key, reason: '${entry.key.label}写进去读回来仍是同一类');
      expect(memory.content, '${entry.key.label}的一条');
      expect(memory.searchTerms, '${entry.key.label} 线索');
      expect(memory.status, MemoryStatus.active);
    }

    // 旧四类标签不再写进库；库的 CHECK 约束直接拒绝这些取值。
    await expectLater(
      insertRow(rig.db, 'memory', {
        'id': 'm-legacy',
        'kind': 'difficulty',
        'content': '旧数据里的困难',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      throwsA(anything),
    );
    await expectLater(
      insertRow(rig.db, 'memory', {
        'id': 'm-legacy-2',
        'kind': 'preference',
        'content': '旧数据里的偏好',
        'source_kind': 'user',
        'status': 'active',
        'created_at': '2026-11-10 09:00:00',
        'updated_at': '2026-11-10 09:00:00',
      }),
      throwsA(anything),
    );
    // 读旧数据时按映射归到三类。
    expect(memoryKindFromLegacy('difficulty'), MemoryKind.episodic);
    expect(memoryKindFromLegacy('progress'), MemoryKind.episodic);
    expect(memoryKindFromLegacy('constraint'), MemoryKind.semantic);
    expect(memoryKindFromLegacy('preference'), MemoryKind.semantic);
    expect(memoryKindForContent('晚上只能学一小时'), MemoryKind.semantic);
    expect(memoryKindForContent('喜欢先看例子'), MemoryKind.semantic);
  });

  test('记忆正文的表的长度上限是 2000 字，超出时库直接拒绝', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);

    final base = {
      'kind': 'semantic',
      'source_kind': 'user',
      'status': 'active',
      'created_at': '2026-11-10 09:00:00',
      'updated_at': '2026-11-10 09:00:00',
    };
    await insertRow(rig.db, 'memory', {
      'id': 'm-2000',
      'content': '长' * 2000,
      ...base,
    });
    expect((await _row(rig, 'm-2000'))['content'], '长' * 2000);

    await expectLater(
      insertRow(rig.db, 'memory', {
        'id': 'm-2001',
        'content': '长' * 2001,
        ...base,
      }),
      throwsA(anything),
    );
  });

  test('过期与删除的记忆不进入上下文', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);
    final now = DateTime.now();

    await repo.create(
      kind: MemoryKind.semantic,
      content: '本周只有半小时',
      validUntil: DateTime(2020),
    );
    await repo.create(kind: MemoryKind.semantic, content: '晚上学习');
    final future = await repo.create(
      kind: MemoryKind.episodic,
      content: '放缩方向不确定',
      validUntil: now.add(const Duration(days: 7)),
    );

    final context = await repo.activeForContext(now: now);
    expect(context.map((memory) => memory.content), contains('晚上学习'));
    expect(context.map((memory) => memory.content), contains('放缩方向不确定'));
    expect(context.map((memory) => memory.content), isNot(contains('本周只有半小时')));

    await repo.delete(future);
    final after = await repo.activeForContext(now: now);
    expect(after.map((memory) => memory.content), isNot(contains('放缩方向不确定')));

    // 删除是状态改成 deleted，行仍然保留；状态只有有效与已删除两种。
    final all = await repo.list(includeInactive: true);
    expect(all, hasLength(3));
    expect(
      all.where((memory) => memory.status == MemoryStatus.deleted).single.id,
      future,
    );
    expect(
      all.where((memory) => memory.status == MemoryStatus.active),
      hasLength(2),
    );
  });

  test('删除是软删除，恢复后重新可用', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);
    final id = await repo.create(
      kind: MemoryKind.episodic,
      content: '第 8 题独立完成',
    );
    await repo.delete(id);
    expect(await repo.activeForContext(now: DateTime.now()), isEmpty);
    final deleted = await repo.byId(id);
    expect(deleted, isNotNull, reason: '删除只改状态，不物理删行');
    expect(deleted!.status, MemoryStatus.deleted);
    await repo.restore(id);
    expect(await repo.activeForContext(now: DateTime.now()), hasLength(1));
  });

  test('记忆不按更新时间只取最近二十条，常驻的排在带范围的与情景之前', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);
    final now = DateTime.now();

    await repo.create(kind: MemoryKind.semantic, content: '这周晚上只有半小时');
    await repo.create(kind: MemoryKind.procedural, content: '先写条件再算');
    for (var index = 0; index < 45; index++) {
      await repo.create(kind: MemoryKind.episodic, content: '进展 $index');
    }

    final context = await repo.activeForContext(now: now);
    // 默认上限 40 条；常驻（语义或程序、全局、长期）在前，再按更新时间倒序。
    expect(context, hasLength(40));
    expect(
      context.take(2).map((memory) => memory.content),
      containsAll(['这周晚上只有半小时', '先写条件再算']),
    );
    expect(
      context.skip(2).map((memory) => memory.content),
      everyElement(startsWith('进展 ')),
    );
  });

  test('有范围的记忆只在同一范围进入上下文', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);
    final now = DateTime.now();

    await repo.create(kind: MemoryKind.semantic, content: '晚上学习');
    await repo.create(
      kind: MemoryKind.episodic,
      content: '放缩方向不确定',
      scope: memoryGoalScope('goal-1'),
    );
    await repo.create(
      kind: MemoryKind.episodic,
      content: '能独立做极限题',
      scope: memoryGoalScope('goal-2'),
    );

    final second = await repo.activeForContext(
      now: now,
      scope: memoryGoalScope('goal-2'),
    );
    expect(second.map((memory) => memory.content), contains('晚上学习'));
    expect(second.map((memory) => memory.content), contains('能独立做极限题'));
    expect(second.map((memory) => memory.content), isNot(contains('放缩方向不确定')));

    final global = await repo.activeForContext(now: now);
    expect(global.map((memory) => memory.content), ['晚上学习']);
  });

  test('某类记忆按范围读出，情景标签下困难与进展都能取到来源作答', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);

    await repo.create(
      kind: MemoryKind.episodic,
      content: '放缩方向不确定',
      scope: memoryGoalScope('goal-1'),
      sourceKind: MemorySourceKind.attempt,
      sourceId: 'attempt-1',
    );
    await repo.create(
      kind: MemoryKind.episodic,
      content: '另一个目标的情景记忆',
      scope: memoryGoalScope('goal-2'),
    );
    await repo.create(kind: MemoryKind.episodic, content: '没有范围的情景记忆');
    await repo.create(
      kind: MemoryKind.procedural,
      content: '同一目标下的做法',
      scope: memoryGoalScope('goal-1'),
    );

    final items = await repo.activeByKind(
      MemoryKind.episodic,
      memoryGoalScope('goal-1'),
    );
    expect(items.map((item) => item.content), ['放缩方向不确定']);
    expect(items.single.sourceId, 'attempt-1');
  });

  test('修改是原地改写：同一行换内容与线索，更新时间前进', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(
      rig.db,
      clock: _clockAt([DateTime(2026, 11, 10, 9), DateTime(2026, 11, 11, 9)]),
    );
    final id = await repo.create(
      kind: MemoryKind.semantic,
      content: '旧说法',
      searchTerms: '旧线索',
    );
    final before = await _row(rig, id);

    await repo.updateContent(
      id,
      content: '新的说法',
      kind: MemoryKind.procedural,
      searchTerms: '新线索',
    );
    final after = await _row(rig, id);
    expect(after['id'], id, reason: '修改不新增行');
    expect(after['content'], '新的说法');
    expect(after['kind'], 'procedural');
    expect(after['search_terms'], '新线索');
    expect(after['created_at'], before['created_at']);
    expect(
      DateTime.parse(after['updated_at']! as String)
          .isAfter(DateTime.parse(before['updated_at']! as String)),
      isTrue,
    );
    expect(await selectRows(rig.db, 'memory'), hasLength(1));
  });

  test('确认保留只写 reviewed_at，不更新 updated_at', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(
      rig.db,
      clock: () => DateTime(2026, 11, 12, 10),
    );
    final id = await repo.create(kind: MemoryKind.semantic, content: '晚上学习');
    final before = await _row(rig, id);
    expect(before['reviewed_at'], isNull);

    await repo.markReviewed(id, at: DateTime(2026, 11, 20, 20));

    final after = await _row(rig, id);
    expect(after['reviewed_at'], '2026-11-20 20:00:00');
    expect(after['updated_at'], before['updated_at'], reason: '确认保留不改更新时间');
    final memory = await repo.byId(id);
    expect(memory!.reviewedAt, DateTime(2026, 11, 20, 20));
    expect(memory.updatedAt, DateTime(2026, 11, 12, 10));
  });

  test('线索为空时写空串，修改时旧线索不留在新正文后面', () async {
    final rig = await openTestRig();
    addTearDown(rig.close);
    final repo = MemoryRepository(rig.db);
    final id = await repo.create(kind: MemoryKind.semantic, content: '晚上学习');
    expect((await _row(rig, id))['search_terms'], '');

    await repo.updateContent(
      id,
      content: '晚上学习',
      kind: MemoryKind.semantic,
      searchTerms: '晚上 学习时间',
    );
    expect((await _row(rig, id))['search_terms'], '晚上 学习时间');
    await repo.updateContent(id, content: '晚上学习', kind: MemoryKind.semantic);
    expect((await _row(rig, id))['search_terms'], '', reason: '修改时拿不到线索就写空串');
  });
}
