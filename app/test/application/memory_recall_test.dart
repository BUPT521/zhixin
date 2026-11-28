import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/application/memory_recall.dart';
import 'package:zhixin/data/repository/memory_repository.dart';
import 'package:zhixin/domain/models/memory.dart';
import 'package:zhixin/domain/rules/time_policy.dart';

import '../support/test_db.dart';

/// 排序替身：按给定顺序返回候选，并记下调用参数。
class _FakeRanker implements MemoryRelevanceRanker {
  _FakeRanker(this.order, {this.available = true});

  /// 期望排在前面的记忆编号。
  final List<String> order;

  /// 为假时模拟索引打不开，调用方应当退回二元组排序。
  final bool available;

  String? query;
  List<String> candidates = const [];
  List<Memory> memories = const [];

  @override
  Future<List<String>?> rankMemories({
    required String query,
    required List<Memory> memories,
    required List<String> candidateIds,
  }) async {
    this.query = query;
    this.memories = memories;
    candidates = candidateIds;
    if (!available) return null;
    return [
      for (final id in order)
        if (candidateIds.contains(id)) id,
    ];
  }
}

/// 用仓库写一条记忆：类型、正文、范围与有效期都走生产写入路径。
Future<String> _create(
  MemoryRepository repo, {
  String? id,
  required MemoryKind kind,
  required String content,
  String? scope,
  DateTime? validUntil,
  MemorySourceKind sourceKind = MemorySourceKind.user,
  String? sourceId,
}) => repo.create(
  id: id,
  kind: kind,
  content: content,
  scope: scope,
  sourceKind: sourceKind,
  sourceId: sourceId,
  validUntil: validUntil,
);

void main() {
  test('常驻的语义与程序排在情景之前，三种用途拿到同一组候选', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 12, 10);
    // 写入时刻固定且彼此可区分：常驻层按更新时间倒序，语义那条比程序更晚。
    final episodicAt = DateTime(2026, 11, 12, 9);
    final proceduralAt = DateTime(2026, 11, 12, 9, 10);
    final semanticAt = DateTime(2026, 11, 12, 9, 20);
    // 先写情景，再写两条全局长期：常驻（语义或程序、全局、无有效期）排在前面。
    await _create(
      MemoryRepository(db, clock: _clockAt(episodicAt)),
      id: 'm-episodic',
      kind: MemoryKind.episodic,
      content: '放缩方向不确定',
    );
    await _create(
      MemoryRepository(db, clock: _clockAt(proceduralAt)),
      id: 'm-procedural',
      kind: MemoryKind.procedural,
      content: '这周晚上只有半小时',
    );
    await _create(
      MemoryRepository(db, clock: _clockAt(semanticAt)),
      id: 'm-semantic',
      kind: MemoryKind.semantic,
      content: '讲解时先给一个例子',
    );

    final recall = MemoryRecallService(MemoryRepository(db));
    final result = await recall.recall(
      now: now,
      purpose: MemoryRecallPurpose.chat,
    );
    expect(result.resident.map((memory) => memory.content).toList(), [
      '讲解时先给一个例子',
      '这周晚上只有半小时',
    ]);
    expect(result.related.map((memory) => memory.content).toList(), [
      '放缩方向不确定',
    ]);
    expect(result.all.map((memory) => memory.content).toList(), [
      '讲解时先给一个例子',
      '这周晚上只有半小时',
      '放缩方向不确定',
    ]);
    // “按用途挑选类别”的规则已经去掉：规划、讲解与检查拿到同一组、同一顺序。
    for (final purpose in [
      MemoryRecallPurpose.plan,
      MemoryRecallPurpose.explain,
      MemoryRecallPurpose.check,
    ]) {
      final results = await recall.recall(now: now, purpose: purpose);
      expect(
        results.all.map((memory) => memory.content).toList(),
        result.all.map((memory) => memory.content).toList(),
        reason: '$purpose 不再按用途调整类别的先后',
      );
    }
  });

  test('常驻要三条都成立：带范围、带有效期或情景都不常驻', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db);
    final now = DateTime(2026, 11, 12, 10);
    await _create(
      repo,
      id: 'm-scoped',
      kind: MemoryKind.semantic,
      content: '这个目标下的限制',
      scope: memoryGoalScope('goal-1'),
    );
    await _create(
      repo,
      id: 'm-dated',
      kind: MemoryKind.semantic,
      content: '这周只看第一章',
      validUntil: DateTime(2026, 11, 20),
    );
    await _create(
      repo,
      id: 'm-episodic',
      kind: MemoryKind.episodic,
      content: '第 8 题独立完成',
    );
    await _create(
      repo,
      id: 'm-resident',
      kind: MemoryKind.procedural,
      content: '先给例子再给定义',
    );

    final result = await MemoryRecallService(repo).recall(
      now: now,
      purpose: MemoryRecallPurpose.chat,
      scope: memoryGoalScope('goal-1'),
    );
    expect(result.resident.map((memory) => memory.id), ['m-resident']);
    expect(
      result.related.map((memory) => memory.id),
      unorderedEquals(['m-scoped', 'm-dated', 'm-episodic']),
    );
  });

  test('候选超过 40 条时截到 40 条，常驻先占名额', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 12, 10);
    final repo = MemoryRepository(db);
    await _create(
      repo,
      id: 'm-long',
      kind: MemoryKind.semantic,
      content: '讲' * 300,
    );
    await _create(
      repo,
      id: 'm-global',
      kind: MemoryKind.procedural,
      content: '这周晚上只有半小时',
    );
    for (var index = 0; index < 45; index++) {
      await _create(
        repo,
        id: 'm-episodic-$index',
        kind: MemoryKind.episodic,
        content: '进展 $index',
      );
    }

    final candidates = await repo.activeForContext(now: now, limit: null);
    expect(candidates.take(2).map((memory) => memory.id).toSet(), {
      'm-long',
      'm-global',
    }, reason: '仓库先按常驻在前读出候选');
    final result = await MemoryRecallService(repo)
        .recall(now: now, purpose: MemoryRecallPurpose.plan);
    expect(result.resident.map((memory) => memory.id).toSet(), {
      'm-global',
      'm-long',
    });
    expect(result.related, hasLength(38));
    expect(result.all, hasLength(40));
    expect(
      result.all.map((memory) => memory.content),
      containsAll(['讲' * 300, '这周晚上只有半小时']),
      reason: '常驻的两条不会被 45 条情景挤出名额',
    );

    final memory = await MemoryRepository(db).byId('m-long');
    final prompt = buildBuddySystemPrompt(
      BuddyContext(now: now, memories: [memory!]),
    );
    expect(prompt, contains('讲' * 200));
    expect(prompt, isNot(contains('讲' * 201)));
    expect(prompt, contains('用户本轮说明优先于下面记住的旧偏好'));
  });

  test('有查询时相关性先于更新时间', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db);
    await _create(
      repo,
      id: 'm-old',
      kind: MemoryKind.episodic,
      content: '条件概率与独立性可以一起判断：P(AB)=P(A)P(B)。',
    );
    await _create(
      repo,
      id: 'm-new',
      kind: MemoryKind.episodic,
      content: '今天状态一般，先做简单题。',
    );

    final result = await MemoryRecallService(repo).recall(
      now: DateTime(2026, 11, 12, 10),
      purpose: MemoryRecallPurpose.check,
      query: '条件概率 独立性',
    );
    expect(result.related.first.content, contains('条件概率与独立性'));
  });

  test('过期、删除与其他范围的记忆不进入召回', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db);
    final now = DateTime(2026, 11, 12, 10);
    await _create(
      repo,
      id: 'm-global',
      kind: MemoryKind.semantic,
      content: '晚上学习',
    );
    await _create(
      repo,
      id: 'm-expired',
      kind: MemoryKind.semantic,
      content: '这周先只看第一章',
      validUntil: DateTime(2026, 11, 11, 10),
    );
    await _create(
      repo,
      id: 'm-deleted',
      kind: MemoryKind.episodic,
      content: '暂时不再用这条',
    );
    await repo.delete('m-deleted');
    await _create(
      repo,
      id: 'm-other',
      kind: MemoryKind.episodic,
      content: '另一个目标的卡点',
      scope: memoryGoalScope('goal-2'),
    );

    final result = await MemoryRecallService(repo).recall(
      now: now,
      purpose: MemoryRecallPurpose.chat,
      scope: memoryGoalScope('goal-1'),
    );
    expect(result.all.map((memory) => memory.content), ['晚上学习']);
  });

  test('带来源的条目保留来源，同类里最近的排在前面', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 12, 10);
    final older = DateTime(2026, 11, 12, 9, 5);
    final newer = DateTime(2026, 11, 12, 9, 30);
    final repo = MemoryRepository(db, clock: _clockAt(older));
    await _create(
      repo,
      id: 'm-manual',
      kind: MemoryKind.episodic,
      content: '手工写下的进展',
    );
    final laterRepo = MemoryRepository(db, clock: _clockAt(newer));
    await _create(
      laterRepo,
      id: 'm-attempt',
      kind: MemoryKind.episodic,
      content: '来自作答的进展：第 8 题独立完成',
      sourceKind: MemorySourceKind.attempt,
      sourceId: 'attempt-7',
    );

    final result = await MemoryRecallService(repo)
        .recall(now: now, purpose: MemoryRecallPurpose.check);
    expect(result.related, hasLength(2));
    // 同类里按更新时间倒序：后写的作答来源排前面。
    expect(result.related.first.id, 'm-attempt');
    expect(result.related.first.sourceKind, MemorySourceKind.attempt);
    expect(result.related.first.sourceId, 'attempt-7');
    expect(result.related.last.content, '手工写下的进展');
    expect(result.related.last.sourceKind, MemorySourceKind.user);
  });

  test('索引给出的相关性先于更新时间，范围之外的记忆也进索引', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final now = DateTime(2026, 11, 12, 10);
    final repo = MemoryRepository(db);
    await _create(
      repo,
      id: 'm-old',
      kind: MemoryKind.episodic,
      content: '放缩时先看上下界',
      scope: memoryGoalScope('goal-1'),
    );
    await _create(
      repo,
      id: 'm-new',
      kind: MemoryKind.episodic,
      content: '晚上先做简单题',
      scope: memoryGoalScope('goal-1'),
    );
    await _create(
      repo,
      id: 'm-other',
      kind: MemoryKind.episodic,
      content: '放缩方向不确定',
      scope: memoryGoalScope('goal-2'),
    );
    await _create(
      repo,
      id: 'm-expired',
      kind: MemoryKind.episodic,
      content: '这周先只看第一章',
      validUntil: DateTime(2026, 11, 11, 10),
    );

    final ranker = _FakeRanker(['m-old']);
    final result = await MemoryRecallService(repo, ranker: ranker).recall(
      now: now,
      purpose: MemoryRecallPurpose.plan,
      scope: memoryGoalScope('goal-1'),
      query: '放缩',
    );
    expect(result.related.first.id, 'm-old', reason: '索引认为它最相关');
    expect(ranker.query, '放缩');
    expect(ranker.candidates, unorderedEquals(['m-new', 'm-old']));
    expect(
      ranker.memories.map((memory) => memory.id),
      unorderedEquals(['m-old', 'm-new', 'm-other']),
      reason: '范围之外的记忆留在索引里，换目标时不必重写',
    );
    expect(
      ranker.memories.map((memory) => memory.id),
      isNot(contains('m-expired')),
      reason: '过期的条目不再同步进索引',
    );
  });

  test('索引不可用时退回二元组排序', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final repo = MemoryRepository(db);
    await _create(
      repo,
      id: 'm-old',
      kind: MemoryKind.episodic,
      content: '条件概率与独立性可以一起判断：P(AB)=P(A)P(B)。',
    );
    await _create(
      repo,
      id: 'm-new',
      kind: MemoryKind.episodic,
      content: '今天状态一般，先做简单题。',
    );

    final ranker = _FakeRanker(const [], available: false);
    final result = await MemoryRecallService(repo, ranker: ranker).recall(
      now: DateTime(2026, 11, 12, 10),
      purpose: MemoryRecallPurpose.check,
      query: '条件概率 独立性',
    );
    expect(ranker.query, '条件概率 独立性');
    expect(result.related.first.content, contains('条件概率与独立性'));
  });

  test('相关程度相同时按更新时间倒序', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final first = DateTime(2026, 11, 12, 9);
    final second = DateTime(2026, 11, 12, 9, 30);
    await _create(
      MemoryRepository(db, clock: _clockAt(first)),
      id: 'm-first',
      kind: MemoryKind.episodic,
      content: '第一件写下的情景',
      scope: memoryGoalScope('g'),
    );
    await _create(
      MemoryRepository(db, clock: _clockAt(second)),
      id: 'm-second',
      kind: MemoryKind.episodic,
      content: '第二件写下的情景',
      scope: memoryGoalScope('g'),
    );
    final result = await MemoryRecallService(MemoryRepository(db)).recall(
      now: DateTime(2026, 11, 12, 10),
      purpose: MemoryRecallPurpose.chat,
      scope: memoryGoalScope('g'),
      query: '无关的查询',
    );
    // 索引对两条都没命中时名次相同，回落按更新时间倒序。
    expect(result.related.map((memory) => memory.id), ['m-second', 'm-first']);
  });

  test('提示词按三类分组，说明每种记忆的用法', () async {
    const memories = [
      Memory(id: 'm-1', kind: MemoryKind.episodic, content: '第 8 题在放缩这一步卡住'),
      Memory(id: 'm-2', kind: MemoryKind.semantic, content: '每周只有两晚能学习'),
      Memory(id: 'm-3', kind: MemoryKind.procedural, content: '讲到矩阵时先给 2 阶例子'),
    ];
    final prompt = buildBuddySystemPrompt(
      BuddyContext(now: DateTime(2026, 11, 12), memories: memories),
    );
    expect(prompt, contains('[情景] 是发生过的一件事'));
    expect(prompt, contains('[语义] 是稳定的事实与限制'));
    expect(prompt, contains('[程序] 是该怎么做的做法'));
    expect(prompt, contains('- 情景：第 8 题在放缩这一步卡住'));
    expect(prompt, contains('- 语义：每周只有两晚能学习'));
    expect(prompt, contains('- 程序：讲到矩阵时先给 2 阶例子'));
  });
}

/// 固定时钟，供需要显式时刻的用例使用。
Clock _clockAt(DateTime at) =>
    () => at;
