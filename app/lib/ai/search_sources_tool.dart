import '../domain/models/buddy_protocol.dart';
import '../domain/models/evidence.dart';
import '../domain/models/material.dart';
import 'agent_read_budget.dart';
import 'agent_tools.dart';
import 'llm_client.dart';

const searchSourcesTool = 'search_sources';

/// 首轮证据不足时才开放补搜：既没有检索摘录，也没有其他材料页可读。
bool canSearchSources(BuddyContext context) =>
    context.sourceSearch != null &&
    context.mode != BuddyMode.plan &&
    context.evidence.isEmpty &&
    context.additionalMaterialHits.isEmpty;

AgentTool searchSourcesReader(
  SourceSearch search, {
  required AgentReadBudget budget,
  required List<CitationSource> providedSources,
  required Map<(int, int), MaterialHit> pages,
}) {
  final reader = _SourceReader(
    search: search,
    budget: budget,
    providedSources: providedSources,
    pages: pages,
  );
  return AgentTool(
    schema: const LlmTool(
      name: searchSourcesTool,
      description:
          '首轮摘录不足时，在本轮范围与用户带入的来源内改写查询补搜。'
          '每轮最多调用两次，每次最多五条候选，摘录约两百字；'
          '不能扩大到当前目标、材料与这条讨论之外。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
            'description': '改写后的查询，保留题号、公式或原句',
          },
        },
        'required': ['query'],
      },
    ),
    execute: (args, resultTokens) =>
        reader.read((args['query'] as String).trim()),
  );
}

class _SourceReader {
  _SourceReader({
    required this.search,
    required this.budget,
    required this.providedSources,
    required this.pages,
  });

  static const int maxCalls = 2;
  static const int maxResults = 5;
  static const int excerptLength = 200;

  final SourceSearch search;
  final AgentReadBudget budget;
  final List<CitationSource> providedSources;

  /// 补搜到的材料页加进本轮可补读的页，模型可以继续用材料读取工具分段读原文。
  final Map<(int, int), MaterialHit> pages;
  var _calls = 0;

  Future<AgentToolResult> read(String query) async {
    if (query.isEmpty) {
      return const AgentToolResult.invalid('query 不能为空');
    }
    if (_calls >= maxCalls) {
      return const AgentToolResult.error(
        'search_limit',
        '本轮补搜已经达到两次上限，请根据已有内容回答',
      );
    }
    if (budget.exhausted) {
      return const AgentToolResult.error('read_limit', '本轮材料读取已达上限，请根据已有内容回答');
    }
    _calls++;
    final hits = await search(query, maxResults);
    if (hits.isEmpty) {
      return const AgentToolResult.unchanged('没有找到更多记录，请根据已有内容回答');
    }
    final results = <Map<String, Object?>>[];
    for (final hit in hits.take(maxResults)) {
      final text = hit.text.trim().isEmpty ? hit.snippet : hit.text;
      final excerpt = _excerpt(text);
      if (!budget.take(excerpt.runes.length)) break;
      results.add({
        'source': hit.identity,
        'kind': hit.kind.value,
        'title': hit.title,
        'excerpt': excerpt,
      });
      final materialId = hit.location.materialId;
      final pageNo = hit.location.pageNo;
      if (hit.kind == EvidenceKind.materialPage &&
          materialId != null &&
          pageNo != null) {
        pages.putIfAbsent(
          (materialId, pageNo),
          () => MaterialHit(
            materialId: materialId,
            materialTitle: _materialTitle(hit.title),
            pageNo: pageNo,
            content: hit.text,
          ),
        );
        providedSources.add(
          CitationSource(
            materialId: materialId,
            pageNo: pageNo,
            content: hit.text,
            materialTitle: _materialTitle(hit.title),
            sourceVersion: hit.sourceVersion,
          ),
        );
      }
    }
    if (results.isEmpty) {
      return const AgentToolResult.error('read_limit', '本轮材料读取已达上限，请根据已有内容回答');
    }
    return AgentToolResult({
      'query': query,
      'calls_left': maxCalls - _calls,
      'results': results,
    });
  }

  static String _excerpt(String text) {
    final runes = text.runes.toList(growable: false);
    if (runes.length <= excerptLength) return text;
    return '${String.fromCharCodes(runes.take(excerptLength))}…';
  }

  static String _materialTitle(String title) {
    final match = RegExp(r'^《(.+)》第 \d+ 页$').firstMatch(title);
    final name = match?.group(1)?.trim();
    return name == null || name.isEmpty ? '材料' : name;
  }
}
