import 'dart:math' as math;

import '../domain/models/material.dart';
import '../domain/rules/content_identity.dart';
import 'agent_read_budget.dart';
import 'agent_tools.dart';
import 'buddy_protocol.dart';
import 'llm_client.dart';
import 'llm_context_budget.dart';
import 'search_sources_tool.dart';

const readMaterialPageTool = 'read_material_page';

/// 补读的材料页来自首轮检索或本轮补搜；补搜还没有返回材料页时也登记读取
/// 工具，模型看到补搜结果后可以继续分段读取原文。
bool canReadMaterial(BuddyContext context) =>
    context.mode != BuddyMode.plan &&
    (context.additionalMaterialHits.isNotEmpty || canSearchSources(context));

AgentTool materialPageReader(
  Map<(int, int), MaterialHit> pages, {
  AgentReadBudget? readBudget,
}) {
  final reader = _MaterialReader(pages, readBudget ?? AgentReadBudget());
  return AgentTool(
    schema: const LlmTool(
      name: readMaterialPageTool,
      description:
          '当材料检索摘录不足以回答时，读取本轮检索命中的指定材料页原文。'
          'offset 按 Unicode 字符计数，从页首读取时省略，需要后续原文时用 next_offset。',
      parameters: {
        'type': 'object',
        'properties': {
          'material_id': {'type': 'integer'},
          'page_no': {'type': 'integer'},
          'offset': {'type': 'integer', 'minimum': 0},
        },
        'required': ['material_id', 'page_no'],
      },
    ),
    execute: (args, resultTokens) {
      return reader.read(
        args['material_id'] as int,
        args['page_no'] as int,
        args['offset'] as int? ?? 0,
        resultTokens,
      );
    },
  );
}

typedef _ReadRange = ({String id, int start, int end, bool hasMore});

/// 只读本轮已经检索出的材料快照。后续读取不接触数据库或文件。
class _MaterialReader {
  _MaterialReader(Map<(int, int), MaterialHit> pages, this.budget)
    : _pages = pages;

  static const _chunkSize = 8000;
  final Map<(int, int), MaterialHit> _pages;
  final AgentReadBudget budget;
  final _reads = <(int, int), List<_ReadRange>>{};

  AgentToolResult read(
    int materialId,
    int pageNo,
    int offset,
    int resultTokens,
  ) {
    final key = (materialId, pageNo);
    final hit = _pages[key];
    if (hit == null) {
      return const AgentToolResult.error('page_unavailable', '这页材料不在本轮检索结果中');
    }
    final reads = _reads.putIfAbsent(key, () => []);
    var size = math.min(_chunkSize, budget.remaining);
    var index = 0;
    for (; index < reads.length; index++) {
      final read = reads[index];
      if (offset < read.start) {
        size = math.min(size, read.start - offset);
        break;
      }
      if (offset < read.end) {
        return AgentToolResult.unchanged({
          'material_id': materialId,
          'page_no': pageNo,
          'offset': read.start,
          'end_offset': read.end,
          'content_id': read.id,
          'note': '这段原文已在本轮返回，请使用前一次结果',
          'next_offset': ?_nextUnreadOffset(
            reads,
            index + 1,
            read.end,
            read.hasMore,
          ),
        });
      }
    }
    if (budget.remaining == 0) {
      return const AgentToolResult.error('read_limit', '本轮材料读取已达上限，请根据已有内容回答');
    }

    final runes = hit.content.runes.skip(offset).take(size + 1).toList();
    if (runes.isEmpty) {
      return const AgentToolResult.error('offset_out_of_range', '该位置没有可读取的原文');
    }
    var count = math.min(size, runes.length);
    AgentToolResult resultFor(int length, String content, String id) {
      final end = offset + length;
      final hasMore = runes.length > length;
      return AgentToolResult({
        'material_id': materialId,
        'page_no': pageNo,
        'title': hit.materialTitle,
        if (hit.isDocx) 'position': hit.position,
        'offset': offset,
        'end_offset': end,
        'content_id': id,
        'content': content,
        if (budget.remaining > length)
          'next_offset': ?_nextUnreadOffset(reads, index, end, hasMore),
        if (hasMore && budget.remaining == length)
          'note': '本轮材料读取已达上限，请根据已有内容回答',
      });
    }

    // 内容标识的长度固定，按完整回执估算容量，再登记实际返回的范围。
    final placeholder = 'material:${'0' * 64}';
    bool fits(int length) =>
        estimateLlmTextTokens(
          resultFor(
            length,
            String.fromCharCodes(runes.take(length)),
            placeholder,
          ).encoded,
        ) <=
        resultTokens;
    if (!fits(count)) {
      var low = 0;
      var high = count;
      while (low + 1 < high) {
        final middle = (low + high) ~/ 2;
        if (fits(middle)) {
          low = middle;
        } else {
          high = middle;
        }
      }
      count = low;
    }
    if (count == 0) {
      return const AgentToolResult.error(
        'context_limit',
        '本轮上下文不足以继续读取，请根据已有材料回答',
      );
    }
    final end = offset + count;
    final hasMore = runes.length > count;
    final content = String.fromCharCodes(runes.take(count));
    final id = contentId('material', [materialId, pageNo, offset, content]);
    final result = resultFor(count, content, id);
    reads.insert(index, (id: id, start: offset, end: end, hasMore: hasMore));
    budget.remaining -= count;
    return result;
  }

  int? _nextUnreadOffset(
    List<_ReadRange> reads,
    int index,
    int end,
    bool hasMore,
  ) {
    if (budget.remaining == 0) return null;
    while (index < reads.length && reads[index].start == end) {
      final next = reads[index++];
      end = next.end;
      hasMore = next.hasMore;
    }
    return hasMore ? end : null;
  }
}
