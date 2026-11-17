import '../data/repository/memory_repository.dart';
import '../domain/models/memory.dart';
import '../domain/rules/content_identity.dart';
import '../domain/rules/embedding.dart';
import '../domain/rules/search_terms.dart';

/// 按本次用途挑选记忆，给回答提示词使用。
///
/// 先由仓库筛掉过期的、已删除的、已被替代的条目和其他范围的条目，再在这里
/// 按用途与查询相关性取最多 40 条。约束先占预算，其余条目先看用途类别，再按
/// 记忆正文与本次问题的相关性排序；相关性由检索索引给出，索引不可用时退回
/// 本机的二元组切分。更新时间只在相关性与类别都相同时比较。待确认的记忆提案
/// 不在 `memory` 表里，确认之前不会成为候选。
class MemoryRecallService {
  MemoryRecallService(this.repository, {this.ranker});

  final MemoryRepository repository;

  /// 相关性排序用的索引；为空时只用本机的二元组切分。
  final MemoryRelevanceRanker? ranker;

  static const int defaultLimit = 40;

  Future<List<Memory>> recall({
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
    if (candidates.isEmpty) return const [];

    final constraints = [
      for (final memory in candidates)
        if (memory.kind == MemoryKind.constraint) memory,
    ];
    final rest = [
      for (final memory in candidates)
        if (memory.kind != MemoryKind.constraint) memory,
    ];
    final ranks = await _relevanceRanks(rest, query, now);
    final preferred = _preferredKinds(purpose);
    final positions = {
      for (var index = 0; index < rest.length; index++) rest[index].id: index,
    };
    rest.sort((left, right) {
      final leftIndex = positions[left.id] ?? 0;
      final rightIndex = positions[right.id] ?? 0;
      final leftPreferred = preferred.contains(left.kind) ? 0 : 1;
      final rightPreferred = preferred.contains(right.kind) ? 0 : 1;
      if (leftPreferred != rightPreferred) {
        return leftPreferred - rightPreferred;
      }
      final relevance =
          (ranks[leftIndex] ?? rest.length) -
          (ranks[rightIndex] ?? rest.length);
      if (relevance != 0) return relevance;
      if (purpose == MemoryRecallPurpose.check) {
        // 检查优先用带来源的进展：来自作答或场次的进展比手工写下的更可核对。
        final leftSourced =
            left.kind == MemoryKind.progress &&
                left.sourceKind != MemorySourceKind.user
            ? 0
            : 1;
        final rightSourced =
            right.kind == MemoryKind.progress &&
                right.sourceKind != MemorySourceKind.user
            ? 0
            : 1;
        if (leftSourced != rightSourced) return leftSourced - rightSourced;
      }
      final byTime = _compareUpdated(right, left);
      if (byTime != 0) return byTime;
      return right.id.compareTo(left.id);
    });
    return [...constraints, ...rest].take(limit).toList(growable: false);
  }

  static Set<MemoryKind> _preferredKinds(MemoryRecallPurpose purpose) {
    return switch (purpose) {
      // 规划先看时间限制与偏好；讲解先看讲解偏好与本题困难；检查先看进展。
      MemoryRecallPurpose.plan => {MemoryKind.preference},
      MemoryRecallPurpose.explain => {
        MemoryKind.preference,
        MemoryKind.difficulty,
      },
      MemoryRecallPurpose.check => {MemoryKind.progress},
      MemoryRecallPurpose.chat => MemoryKind.values.toSet(),
    };
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

  static int _compareUpdated(Memory left, Memory right) {
    final leftTime = left.updatedAt?.millisecondsSinceEpoch ?? 0;
    final rightTime = right.updatedAt?.millisecondsSinceEpoch ?? 0;
    return leftTime.compareTo(rightTime);
  }
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

/// 记忆的来源版本：正文与更新时间一起参与，编辑、纠正或恢复之后重新写入。
String memorySourceVersion(Memory memory) =>
    contentHash('${memory.content}\n${memory.updatedAt ?? ''}'.codeUnits);

/// 从来源键还原记忆编号；不是记忆来源时返回空。
String? memoryIdOf(String sourceKey) {
  const prefix = 'memory:';
  if (!sourceKey.startsWith(prefix)) return null;
  return sourceKey.substring(prefix.length);
}
