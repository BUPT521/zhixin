import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhixin/ai/agent_read_budget.dart';
import 'package:zhixin/ai/agent_tools.dart';
import 'package:zhixin/ai/buddy_prompt.dart';
import 'package:zhixin/ai/llm_client.dart';
import 'package:zhixin/ai/search_sources_tool.dart';
import 'package:zhixin/domain/models/evidence.dart';
import 'package:zhixin/domain/models/material.dart';

EvidenceHit _page(int pageNo, String content) {
  return EvidenceHit(
    kind: EvidenceKind.materialPage,
    identity: 'material_page:1:$pageNo',
    title: '《概率论讲义》第 $pageNo 页',
    snippet: content,
    matchedText: content,
    literal: false,
    score: 10,
    location: EvidenceLocation(materialId: 1, pageNo: pageNo),
    sourceVersion: 'v$pageNo',
    text: content,
  );
}

BuddyContext _context(
  SourceSearch? search, {
  List<EvidenceHit> evidence = const [],
  List<MaterialHit> materialHits = const [],
}) {
  return BuddyContext(
    now: DateTime(2026, 11, 12, 20),
    evidence: evidence,
    materialHits: materialHits,
    sourceSearch: search,
  );
}

Future<List<Map<String, Object?>>> _run(
  BuddyTurnTools tools,
  String query, {
  String id = 'call_1',
}) async {
  final budget = LlmRequestBudget(timeout: const Duration(seconds: 5));
  final calls = tools.registry.prepare([
    LlmToolCall(
      id: id,
      name: searchSourcesTool,
      arguments: jsonEncode({'query': query}),
    ),
  ], budget);
  final batch = await tools.registry.execute(
    calls,
    budget,
    extraResultTokens: 0,
  );
  final result = batch.outcomes.single.result.content;
  if (result is! Map) return const [];
  return [
    for (final item in (result['results'] as List? ?? const []))
      (item as Map).cast<String, Object?>(),
  ];
}

void main() {
  test('首轮证据不足时开放补搜，每次最多五条，摘录约两百字', () async {
    final hits = [
      for (var page = 1; page <= 7; page++)
        _page(page, '条件概率第 $page 页：${'推导过程。' * 60}'),
    ];
    var queries = <String>[];
    final tools = BuddyTurnTools(
      _context((query, limit) async {
        queries.add('$query/$limit');
        return hits;
      }),
    );
    expect(
      tools.registry.schemas.map((tool) => tool.name),
      contains(searchSourcesTool),
    );

    final first = await _run(tools, '条件概率 推导');
    expect(first, hasLength(5));
    expect(queries, ['条件概率 推导/5']);
    for (final item in first) {
      final excerpt = item['excerpt']! as String;
      expect(excerpt.runes.length, lessThanOrEqualTo(201));
      expect(item['source'], startsWith('material_page:1:'));
    }

    final reply = tools.finish('依据补搜到的条件概率定义回答。');
    expect(reply.providedSources, hasLength(5));
    expect(reply.providedSources.first.sourceVersion, isNotNull);
  });

  test('每轮最多两次补搜，超出后不再查询', () async {
    var calls = 0;
    final tools = BuddyTurnTools(
      _context((query, limit) async {
        calls++;
        return [_page(1, '条件概率定义。')];
      }),
    );
    await _run(tools, '第一次', id: 'a');
    await _run(tools, '第二次', id: 'b');
    final budget = LlmRequestBudget(timeout: const Duration(seconds: 5));
    final prepared = tools.registry.prepare([
      LlmToolCall(
        id: 'c',
        name: searchSourcesTool,
        arguments: '{"query":"第三次"}',
      ),
    ], budget);
    final batch = await tools.registry.execute(
      prepared,
      budget,
      extraResultTokens: 0,
    );
    expect(calls, 2);
    expect(batch.outcomes.single.result.errorCode, 'search_limit');
  });

  test('补搜与材料读取共用四万八千字的读取预算', () async {
    final budget = AgentReadBudget(250);
    final long = '条' * 400;
    final tools = BuddyTurnTools(
      _context((query, limit) async => [_page(1, long), _page(2, long)]),
    );
    // 换成可以观察剩余量的同一份预算：直接构造工具，复用公开构造入口。
    final reader = searchSourcesReader(
      (query, limit) async => [_page(1, long), _page(2, long)],
      budget: budget,
      providedSources: [],
      pages: {},
    );
    final registry = AgentToolSet([reader]);
    final request = LlmRequestBudget(timeout: const Duration(seconds: 5));
    final prepared = registry.prepare([
      LlmToolCall(
        id: 'd',
        name: searchSourcesTool,
        arguments: '{"query":"条件概率"}',
      ),
    ], request);
    final batch = await registry.execute(
      prepared,
      request,
      extraResultTokens: 0,
    );
    final result = batch.outcomes.single.result.content as Map;
    expect((result['results'] as List), hasLength(1));
    expect(budget.remaining, 49);
    expect(tools.registry.schemas, isNotEmpty);

    final emptyBudget = AgentReadBudget(0);
    final blocked = searchSourcesReader(
      (query, limit) async => [_page(1, long)],
      budget: emptyBudget,
      providedSources: [],
      pages: {},
    );
    final blockedRegistry = AgentToolSet([blocked]);
    final blockedCalls = blockedRegistry.prepare([
      LlmToolCall(
        id: 'e',
        name: searchSourcesTool,
        arguments: '{"query":"条件概率"}',
      ),
    ], request);
    final blockedBatch = await blockedRegistry.execute(
      blockedCalls,
      request,
      extraResultTokens: 0,
    );
    expect(blockedBatch.outcomes.single.result.errorCode, 'read_limit');
  });

  test('首轮已有摘录或材料页时不开放补搜', () {
    final hit = _page(1, '条件概率的定义。');
    expect(
      BuddyTurnTools(_context((q, l) async => [hit])).registry.schemas
          .map((tool) => tool.name),
      contains(searchSourcesTool),
    );
    expect(
      BuddyTurnTools(_context((q, l) async => [hit], evidence: [hit]))
          .registry
          .schemas
          .map((tool) => tool.name),
      isNot(contains(searchSourcesTool)),
    );
    expect(
      BuddyTurnTools(
        _context(
          (q, l) async => [hit],
          materialHits: [
            const MaterialHit(
              materialId: 1,
              materialTitle: '概率论讲义',
              pageNo: 1,
              content: '条件概率的定义。',
            ),
          ],
        ),
      ).registry.schemas.map((tool) => tool.name),
      isNot(contains(searchSourcesTool)),
    );
  });
}
