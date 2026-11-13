import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zhixin/application/evidence_service.dart';
import 'package:zhixin/data/db/raw_executor.dart';
import 'package:zhixin/application/search_service.dart';
import 'package:zhixin/data/repository/attempt_repository.dart';
import 'package:zhixin/data/repository/conversation_repository.dart';
import 'package:zhixin/data/repository/evidence_repository.dart';
import 'package:zhixin/data/repository/material_repository.dart';
import 'package:zhixin/data/repository/task_repository.dart';
import 'package:zhixin/domain/rules/search_terms.dart';
import 'package:zhixin/domain/rules/time_format.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/search.dart';

import '../support/test_db.dart';

List<EvidenceHit> _hits(SearchResults results) => [
  for (final entry in results.entries) ...entry.hits,
];

EvidenceHit _singleHit(SearchResults results, EvidenceKind kind) =>
    _hits(results).singleWhere((hit) => hit.kind == kind);

String _conversationKey(int id) => 'conversation:$id';

Iterable<int?> _materialPages(SearchResults results) =>
    _hits(results)
        .where((hit) => hit.kind == EvidenceKind.materialPage)
        .map((hit) => hit.location.pageNo);

void main() {
  setUpAll(sqfliteFfiInit);

  test('记录检索覆盖全部目标的讨论、题目与材料', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final attempts = AttemptRepository(db.rawDb);
    final materials = MaterialRepository(db.rawDb);
    final tasks = TaskRepository(db.rawDb);
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );

    final goalA = await tasks.createGoal(title: '概率论期末');
    final goalB = await tasks.createGoal(title: '线性代数作业');

    final probability = await conversations.create(title: '条件概率讨论');
    await conversations.setGoal(probability, goalA);
    await conversations.append(
      probability,
      role: 'user',
      content: '条件概率和独立性有什么区别',
    );
    final linear = await conversations.create(title: '矩阵的秩');
    await conversations.setGoal(linear, goalB);
    await conversations.append(linear, role: 'user', content: '矩阵的秩怎么求');

    final question = await conversations.create(sourceRef: '第 3 章第 8 题');
    await conversations.append(
      question,
      role: 'user',
      content: '条件概率习题：求 P(A|B)',
    );
    await attempts.ensureOpenAttempt(question);

    final material = await materials.create(
      title: '线性代数讲义',
      kind: 'book',
      goalId: goalB,
    );
    await materials.addPage(
      materialId: material,
      pageNo: 3,
      content: '矩阵的秩是线性无关行向量的最大个数。',
    );

    // 用户主动检索不按目标过滤，两个目标的记录都能找到。
    final probabilityResults = await search.search('条件概率');
    expect(
      probabilityResults.entries.map((entry) => entry.key),
      containsAll([_conversationKey(probability), _conversationKey(question)]),
    );
    expect(
      _singleHit(
        probabilityResults,
        EvidenceKind.question,
      ).location.conversationId,
      question,
    );
    expect(
      _hits(probabilityResults)
          .any((hit) => hit.kind == EvidenceKind.materialPage),
      isFalse,
    );

    final linearResults = await search.search('矩阵');
    expect(
      _singleHit(linearResults, EvidenceKind.message).location.conversationId,
      linear,
    );
    final linearMaterial = _singleHit(linearResults, EvidenceKind.materialPage);
    expect(linearMaterial.location.materialId, material);
    expect(linearMaterial.title, contains('线性代数讲义'));

    final rankResults = await search.search('线性无关');
    final rankMaterial = _singleHit(rankResults, EvidenceKind.materialPage);
    expect(rankMaterial.location.materialId, material);
    expect(rankMaterial.location.pageNo, 3);

    // 整句提问也要能按其中的词找到材料页，而不是整句一起匹配。
    final natural = await search.search('矩阵的秩是怎么定义的');
    final naturalMaterial = _singleHit(natural, EvidenceKind.materialPage);
    expect(naturalMaterial.location.materialId, material);
    expect(naturalMaterial.location.pageNo, 3);

    // 目标内的检索不带出别的目标的材料页。
    final probabilityMaterial = await materials.create(
      title: '概率论讲义',
      kind: 'text',
      goalId: goalA,
    );
    await materials.addPage(
      materialId: probabilityMaterial,
      pageNo: 1,
      content: '条件概率 P(A|B)=P(AB)/P(B)。',
    );
    final linearOnly = await materials.search('矩阵', goalId: goalA);
    expect(linearOnly, isEmpty);
    final probabilityInA = await materials.search('条件概率', goalId: goalA);
    expect(probabilityInA.single.materialId, probabilityMaterial);
    final probabilityInB = await materials.search('条件概率', goalId: goalB);
    expect(probabilityInB, isEmpty);

    // 单字术语也要能检索；结果仍由记录条数决定，不再被长度门槛挡掉。
    final single = await search.search('秩');
    expect(
      _singleHit(single, EvidenceKind.materialPage).location.materialId,
      material,
    );
  });

  test('检索关键词不再按固定个数截断', () {
    final terms = searchTerms('矩阵 行列式 特征值 特征向量 线性空间 维数 秩数 基础 向量 空间');

    expect(terms, hasLength(10));
    expect(terms.last, '空间');
  });

  test('记录检索返回全部命中的讨论与材料页，不再每组只取六条', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final materials = MaterialRepository(db.rawDb);
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );

    for (var index = 0; index < 8; index++) {
      final conversation = await conversations.create(title: '矩阵讨论 $index');
      await conversations.append(
        conversation,
        role: 'user',
        content: '矩阵的第 $index 个问题怎么算',
      );
    }
    final material = await materials.create(title: '矩阵讲义');
    for (var page = 1; page <= 8; page++) {
      await materials.addPage(
        materialId: material,
        pageNo: page,
        content: '第 $page 页讲矩阵的运算。',
      );
    }

    final results = await search.search('矩阵');

    expect(
      _hits(results).where((hit) => hit.kind == EvidenceKind.message),
      hasLength(8),
    );
    expect(
      _hits(results).where((hit) => hit.kind == EvidenceKind.materialPage),
      hasLength(8),
    );
  });

  test('材料先按全部候选相关性排序，摘要围绕命中内容生成', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final materials = MaterialRepository(db.rawDb);
    final oldMaterial = await materials.create(title: '较早的矩阵材料');
    final matchingText = '${List.filled(24, '背景内容。').join()}矩阵与独立性需要同时核对。';
    await materials.addPage(
      materialId: oldMaterial,
      pageNo: 12,
      content: matchingText,
    );
    final recentMaterial = await materials.create(title: '近期材料');
    for (var page = 1; page <= 20; page++) {
      await materials.addPage(
        materialId: recentMaterial,
        pageNo: page,
        content: '矩阵这一项命中，但没有提到另一个关键词。',
      );
    }

    final hits = await materials.search('矩阵 独立性', limit: 4);
    expect(hits.first.materialId, oldMaterial);
    expect(hits.first.pageNo, 12);
    expect(hits.first.snippet, contains('独立性'));
  });

  test('同类命中超过四十条时分页在去重之后进行，最早一条可达', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );
    final base = DateTime(2026, 10, 1);
    final ids = <int>[];
    for (var index = 0; index < 60; index++) {
      final conversation = await conversations.create(title: '矩阵讨论 $index');
      ids.add(conversation);
      await conversations.append(
        conversation,
        role: 'user',
        content: '矩阵的第 $index 个问题怎么算',
      );
      final at = formatDateTime(base.add(Duration(minutes: index)));
      await db.update(
        'message',
        {'created_at': at},
        where: 'conversation_id = ?',
        whereArgs: [conversation],
      );
      await db.update(
        'conversation',
        {'created_at': at, 'updated_at': at},
        where: 'id = ?',
        whereArgs: [conversation],
      );
    }

    final first = await search.searchPage('矩阵', pageSize: 20);
    expect(first.entries, hasLength(20));
    expect(first.hasMore, isTrue);
    expect(first.nextOffset, 20);

    final second = await search.searchPage(
      '矩阵',
      offset: first.nextOffset,
      pageSize: 20,
    );
    final third = await search.searchPage(
      '矩阵',
      offset: second.nextOffset,
      pageSize: 20,
    );
    expect(third.entries, hasLength(20));
    expect(third.hasMore, isFalse);

    final reached = {
      for (final results in [first, second, third])
        for (final entry in results.entries)
          for (final hit in entry.hits) hit.location.conversationId,
    };
    expect(reached, hasLength(60));
    expect(reached, contains(ids.first), reason: '按时间倒序排列时最早一条在最后一页，也必须能翻到');

    // 同一批候选分页取到的记录，和不分页时一致。
    final all = await search.search('矩阵');
    expect(
      _hits(all).where((hit) => hit.kind == EvidenceKind.message),
      hasLength(60),
    );
  });

  test('较早但更相关的记录排在新记录之前', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );
    final old = await conversations.create(title: '较早的矩阵讨论');
    await conversations.append(
      old,
      role: 'user',
      content: '矩阵与独立性需要同时核对，这里把两件事放在一起讲。',
    );
    await db.update(
      'message',
      {'created_at': '2026-09-01 09:00:00'},
      where: 'conversation_id = ?',
      whereArgs: [old],
    );
    await db.update(
      'conversation',
      {
        'created_at': '2026-09-01 09:00:00',
        'updated_at': '2026-09-01 09:00:00',
      },
      where: 'id = ?',
      whereArgs: [old],
    );
    for (var index = 0; index < 50; index++) {
      final conversation = await conversations.create(title: '新矩阵讨论 $index');
      await conversations.append(
        conversation,
        role: 'user',
        content: '矩阵的第 $index 个问题怎么算',
      );
      final at = formatDateTime(
        DateTime(2026, 10, 10).add(Duration(minutes: index)),
      );
      await db.update(
        'message',
        {'created_at': at},
        where: 'conversation_id = ?',
        whereArgs: [conversation],
      );
      await db.update(
        'conversation',
        {'created_at': at, 'updated_at': at},
        where: 'id = ?',
        whereArgs: [conversation],
      );
    }

    final results = await search.searchPage('矩阵 独立性', pageSize: 20);
    expect(results.entries.first.hits.first.location.conversationId, old);
  });

  test('用户查找按原样区分近似写法', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final materials = MaterialRepository(db.rawDb);
    final material = await materials.create(title: '公式与题号');
    await materials.addPage(
      materialId: material,
      pageNo: 1,
      content: '例 3-2 求条件概率。',
    );
    await materials.addPage(
      materialId: material,
      pageNo: 2,
      content: '例 3-20 是另一道题。',
    );
    await materials.addPage(
      materialId: material,
      pageNo: 3,
      content: '函数写作 f(x)，读作 f 关于 x。',
    );
    await materials.addPage(
      materialId: material,
      pageNo: 4,
      content: '矩阵的第 b 列记作 a_b。',
    );
    await materials.addPage(
      materialId: material,
      pageNo: 5,
      content: '另一种记法 a_bc 不是同一回事。',
    );
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );

    final example = await search.search('例 3-2');
    expect(_materialPages(example), contains(1));
    expect(_materialPages(example), isNot(contains(2)));

    final formula = await search.search('f(x)');
    expect(_materialPages(formula), contains(3));

    final underscore = await search.search('a_b');
    expect(_materialPages(underscore), contains(4));
    expect(_materialPages(underscore), isNot(contains(5)));
  });

  test('同一条学习记录的多条消息只占一页里的一个位置', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );
    final noisy = await conversations.create(title: '矩阵讨论');
    for (var index = 0; index < 3; index++) {
      await conversations.append(
        noisy,
        role: 'user',
        content: '矩阵的第 $index 个问题',
      );
    }
    final ids = <int>[noisy];
    for (var index = 0; index < 24; index++) {
      final conversation = await conversations.create(title: '其他矩阵 $index');
      ids.add(conversation);
      await conversations.append(
        conversation,
        role: 'user',
        content: '矩阵记录 $index',
      );
      await conversations.append(
        conversation,
        role: 'assistant',
        content: '矩阵回答 $index',
      );
      final at = formatDateTime(
        DateTime(2026, 10, 1).add(Duration(minutes: index)),
      );
      await db.update(
        'message',
        {'created_at': at},
        where: 'conversation_id = ?',
        whereArgs: [conversation],
      );
      await db.update(
        'conversation',
        {'created_at': at, 'updated_at': at},
        where: 'id = ?',
        whereArgs: [conversation],
      );
    }

    final first = await search.searchPage('矩阵', pageSize: 20);
    expect(first.entries, hasLength(20));
    expect(
      first.entries
          .where((entry) => entry.key == _conversationKey(noisy))
          .length,
      1,
      reason: '同一条记录只列出相关性最高的一条消息',
    );
    expect(first.hasMore, isTrue);

    final second = await search.searchPage(
      '矩阵',
      offset: first.nextOffset,
      pageSize: 20,
    );
    expect(second.entries, hasLength(5));
    expect(second.hasMore, isFalse);
    final reached = {
      for (final results in [first, second])
        for (final entry in results.entries)
          for (final hit in entry.hits) hit.location.conversationId,
    };
    expect(reached, hasLength(ids.length));
  });

  test('快速切换查询或筛选时只有最后一次请求生效', () {
    final gate = SearchRequestGate();
    final first = gate.start();
    final second = gate.start();
    expect(gate.isCurrent(first), isFalse);
    expect(gate.isCurrent(second), isTrue);

    final third = gate.start();
    expect(gate.isCurrent(second), isFalse);
    expect(gate.isCurrent(third), isTrue);
  });

  test('带语义命中翻页不重不漏，翻到底时结束', () async {
    final db = await openTestDb();
    addTearDown(db.close);
    final conversations = ConversationRepository(db.rawDb);
    final search = SearchService(
      evidence: EvidenceService(repository: EvidenceRepository(db.rawDb)),
    );
    final localIds = <int>[];
    for (var index = 0; index < 25; index++) {
      final id = await conversations.create(title: '矩阵记录 $index');
      localIds.add(id);
      await conversations.append(id, role: 'user', content: '矩阵记录 $index');
    }
    final semanticIds = <int>[];
    for (var index = 0; index < 3; index++) {
      final id = await conversations.create(title: '语义记录 $index');
      semanticIds.add(id);
      await conversations.append(id, role: 'user', content: '线性无关 $index');
    }
    final semanticHits = [
      for (var index = 0; index < semanticIds.length; index++)
        EvidenceHit(
          kind: EvidenceKind.message,
          identity: 'message:${1000 + index}',
          title: '语义记录 $index',
          snippet: '线性无关 $index',
          matchedText: '线性无关 $index',
          literal: false,
          semantic: true,
          score: 10,
          location: EvidenceLocation(
            conversationId: semanticIds[index],
            messageId: 1000 + index,
          ),
        ),
    ];

    final pages = <SearchResults>[];
    var offset = 0;
    while (true) {
      final page = await search.searchPage(
        '矩阵',
        offset: offset,
        pageSize: 10,
        semanticHits: semanticHits,
      );
      pages.add(page);
      if (!page.hasMore) break;
      offset = page.nextOffset;
      expect(pages.length, lessThan(10));
    }

    final keys = [
      for (final page in pages)
        for (final entry in page.entries) entry.key,
    ];
    expect(keys.toSet().length, keys.length, reason: '翻页不重复');
    expect(keys, hasLength(localIds.length + semanticIds.length));
    for (final id in [...localIds, ...semanticIds]) {
      expect(keys, contains(_conversationKey(id)));
    }
    expect(pages.length, 3);
    expect(pages.last.hasMore, isFalse);
    expect(
      [
        for (final page in pages)
          for (final entry in page.entries) entry,
      ].any((entry) => entry.semanticRank != null),
      isTrue,
    );
  });

  test('接上下一页时按来源标识去重，已经显示过的记录不再出现', () {
    EvidenceHit hit(int id) => EvidenceHit(
      kind: EvidenceKind.message,
      identity: 'message:$id',
      title: '矩阵讨论',
      snippet: '矩阵记录 $id',
      matchedText: '矩阵记录 $id',
      literal: false,
      score: 10,
      location: EvidenceLocation(conversationId: id, messageId: id),
    );
    SearchEntry entry(int id) =>
        SearchEntry(key: _conversationKey(id), hits: [hit(id)], localRank: id);
    final first = SearchResults(
      query: '矩阵',
      entries: [entry(1), entry(2)],
      hasMore: true,
      nextOffset: 2,
    );
    final next = SearchResults(
      query: '矩阵',
      entries: [entry(2), entry(3)],
      hasMore: false,
      nextOffset: 3,
    );

    final merged = first.append(next);
    expect(merged.entries.map((entry) => entry.key), [
      'conversation:1',
      'conversation:2',
      'conversation:3',
    ]);
    expect(merged.hasMore, isFalse);
    expect(merged.nextOffset, 3);
  });
}
