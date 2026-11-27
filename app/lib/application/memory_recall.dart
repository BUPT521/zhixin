import '../data/repository/memory_repository.dart';
import '../domain/models/memory.dart';
import '../domain/rules/content_identity.dart';
import '../domain/rules/embedding.dart';
import '../domain/rules/search_terms.dart';

/// 按三层取本次回答要带的记忆（ADR-0051 决定第 5、6 条）。
///
/// 先由仓库筛掉过期的、已删除的、其他范围的条目，再在这里分层：常驻（语义或
/// 程序、范围是全局、没有有效期）排在最前，其余是当前范围内的相关层，按记忆
/// 正文与本次问题的相关性排序，相关程度相同时按更新时间倒序。索引不可用时退回
/// 本机的二元组切分。待确认的记忆提案不在 `memory` 表里，确认之前不会成为
/// 候选。
///
/// 相关层沿用现有“当前范围内的条目全带”的行为，得分下限留到定下来之后才用来
/// 只带达到下限的条目；超过上限时截到上限。召回本身不在每次召回时写库，使用
/// 记录交给 [MemoryUsageService] 在内存与本机缓冲。
class MemoryRecallService {
  MemoryRecallService(this.repository, {this.ranker});

  final MemoryRepository repository;

  /// 相关性排序用的索引；为空时只用本机的二元组切分。
  final MemoryRelevanceRanker? ranker;

  /// 每次回答最多带入的记忆条数。
  static const int defaultLimit = 40;

  Future<MemoryRecallResult> recall({
    required DateTime now,
    required MemoryRecallPurpose purpose,
    String? scope,
    String query = '',
    int limit = defaultLimit,
  }) async {
    final candidates = await repository.activeForContext(
      now: now,
      scope: scope,
      limit: null,
    );
    return rank(candidates: candidates, now: now, query: query, limit: limit);
  }

  /// 把候选分成常驻与相关两层并排出先后；调用方已经按有效性、范围筛过。
  ///
  /// 常驻按更新时间倒序，相关层按检索相关性、再按更新时间倒序。两层合起来
  /// 超过 [limit] 时先截相关层，常驻全带。
  Future<MemoryRecallResult> rank({
    required List<Memory> candidates,
    required DateTime now,
    String query = '',
    int limit = defaultLimit,
  }) async {
    if (candidates.isEmpty) {
      return const MemoryRecallResult(resident: [], related: []);
    }
    final resident = [
      for (final memory in candidates)
        if (memory.resident) memory,
    ]..sort(_byUpdatedDesc);
    final relatedCandidates = [
      for (final memory in candidates)
        if (!memory.resident) memory,
    ];
    final ranks = await _relevanceRanks(relatedCandidates, query, now);
    final positions = {
      for (var index = 0; index < relatedCandidates.length; index++)
        relatedCandidates[index].id: index,
    };
    final related = [...relatedCandidates]
      ..sort((left, right) {
        final byRelevance =
            (ranks[positions[left.id] ?? 0] ?? relatedCandidates.length) -
            (ranks[positions[right.id] ?? 0] ?? relatedCandidates.length);
        if (byRelevance != 0) return byRelevance;
        final byTime = _byUpdatedDesc(left, right);
        if (byTime != 0) return byTime;
        return right.id.compareTo(left.id);
      });
    final room = limit - resident.length;
    return MemoryRecallResult(
      resident: List.unmodifiable(resident),
      related: List.unmodifiable(
        room <= 0 ? const <Memory>[] : related.take(room),
      ),
    );
  }

  /// 候选记忆的名次：先问索引，索引不可用时按二元组切分。
  ///
  /// 没有查询或只有一个候选时保持原顺序。
  Future<Map<int, int>> _relevanceRanks(
    List<Memory> memories,
    String query,
    DateTime now,
  ) async {
    if (memories.length < 2 || query.trim().isEmpty) return const {};
    final indexed = await _indexedRanks(memories, query, now);
    if (indexed != null) return indexed;
    return _bigramRanks(memories, query);
  }

  /// 用检索索引给候选排序；索引不可用或同步失败时返回空值。
  ///
  /// 交给索引的是当前有效且未过期的全部记忆：范围之外的条目留在索引里，换
  /// 目标或材料时不必重新写入；本次范围只决定哪些条目参与排序。
  Future<Map<int, int>?> _indexedRanks(
    List<Memory> memories,
    String query,
    DateTime now,
  ) async {
    final sorter = ranker;
    if (sorter == null) return null;
    try {
      final active = await repository.list();
      final valid = [
        for (final memory in active)
          if (memory.isValidAt(now)) memory,
      ];
      final order = await sorter.rankMemories(
        query: query,
        memories: valid,
        candidateIds: [for (final memory in memories) memory.id],
      );
      return order == null ? null : _ranksFromOrder(memories, order);
    } catch (_) {
      return null;
    }
  }

  /// 命中条目的名次照索引给的先后，未命中的排在它们后面并保持原有顺序。
  static Map<int, int> _ranksFromOrder(
    List<Memory> memories,
    List<String> order,
  ) {
    final hits = <String, int>{};
    for (var rank = 0; rank < order.length; rank++) {
      hits.putIfAbsent(order[rank], () => rank);
    }
    final ranks = <int, int>{};
    var next = order.length;
    for (var index = 0; index < memories.length; index++) {
      ranks[index] = hits[memories[index].id] ?? next++;
    }
    return ranks;
  }

  /// 索引不可用时的本机排序：按命中的二元组数量打分，命中的词越多越前。
  static Map<int, int> _bigramRanks(List<Memory> memories, String query) {
    final wanted = bigrams(query).toSet();
    if (wanted.isEmpty) return const {};
    final scores = <int, int>{
      for (var index = 0; index < memories.length; index++)
        index: bigrams(memories[index].content)
            .toSet()
            .intersection(wanted)
            .length,
    };
    // 并列时按原有顺序，名次因此稳定。
    final order = List<int>.generate(memories.length, (index) => index);
    order.sort((left, right) {
      final byScore = scores[right]!.compareTo(scores[left]!);
      return byScore != 0 ? byScore : left.compareTo(right);
    });
    return {for (final (rank, index) in order.indexed) index: rank};
  }

  /// 更新时间倒序；没有时间的一方排在后面。
  static int _byUpdatedDesc(Memory left, Memory right) {
    final leftTime = left.updatedAt?.millisecondsSinceEpoch ?? 0;
    final rightTime = right.updatedAt?.millisecondsSinceEpoch ?? 0;
    return rightTime.compareTo(leftTime);
  }
}

/// 一次召回的结果：常驻层与相关层分开，两层都按进入提示词的先后排好。
class MemoryRecallResult {
  const MemoryRecallResult({required this.resident, required this.related});

  const MemoryRecallResult.empty() : resident = const [], related = const [];

  final List<Memory> resident;
  final List<Memory> related;

  /// 进入本次提示词的全部记忆：常驻在前，相关层在后。
  List<Memory> get all => [...resident, ...related];

  bool get isEmpty => resident.isEmpty && related.isEmpty;
}

/// 记忆排序用的索引能力；运行时由 `SearchIndexService` 实现。
///
/// 索引只接收调用方读到的记忆条目与本次候选，不读业务库：有效性、范围与
/// 版本仍由仓库层判断。
abstract interface class MemoryRelevanceRanker {
  /// 同步索引之后按 [query] 给出 [candidateIds] 的先后，最相关的在前；
  /// 索引不可用时返回空值，调用方退回本机的二元组排序。
  Future<List<String>?> rankMemories({
    required String query,
    required List<Memory> memories,
    required List<String> candidateIds,
  });
}

/// 记忆在索引里的来源键；与证据来源分开，清理与预过滤都按这个前缀。
String memorySourceKey(String id) => 'memory:$id';

/// 记忆在索引里的定位信息；记忆不属于任何材料或讨论。
SemanticLocator memoryLocator(String id) =>
    SemanticLocator(kind: 'memory', sourceKey: memorySourceKey(id));

/// 记忆的来源版本：正文、更新时间与检索线索一起参与，编辑、纠正或恢复之后
/// 重新写入。
String memorySourceVersion(Memory memory) => contentHash(
  '${memory.content}\n${memory.searchTerms}\n${memory.updatedAt ?? ''}'
      .codeUnits,
);

/// 从来源键还原记忆编号；不是记忆来源时返回空。
String? memoryIdOf(String sourceKey) {
  const prefix = 'memory:';
  if (!sourceKey.startsWith(prefix)) return null;
  return sourceKey.substring(prefix.length);
}
