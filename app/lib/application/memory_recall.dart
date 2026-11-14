import '../data/repository/memory_repository.dart';
import '../domain/models/memory.dart';
import '../domain/rules/binary_bigrams.dart';

/// 按本次用途挑选记忆，给回答提示词使用。
///
/// 先由仓库筛掉过期的、已删除的、已被替代的条目和其他范围的条目，再在这里
/// 按用途与查询相关性取最多 40 条。约束先占预算，其余条目先看用途类别，再按
/// 记忆正文的 BM25 相关性排序；更新时间只在相关性与类别都相同时比较。待确认
/// 的记忆提案不在 `memory` 表里，确认之前不会成为候选。
class MemoryRecallService {
  MemoryRecallService(this.repository);

  final MemoryRepository repository;

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
    final ranks = _relevanceRanks(rest, query);
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
            left.kind == MemoryKind.progress && left.sourceKind != 'user'
            ? 0
            : 1;
        final rightSourced =
            right.kind == MemoryKind.progress && right.sourceKind != 'user'
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

  /// 按记忆正文的相关性给候选排名次；没有查询或只有一个候选时保持原顺序。
  ///
  /// 记忆条数远小于材料页与消息，因此不另建索引表（ADR-0013 第 7 条）：用
  /// 与关键词索引同一套二元组切分，按命中的词数打分，命中的词越多名次越前。
  static Map<int, int> _relevanceRanks(List<Memory> memories, String query) {
    if (memories.length < 2 || query.trim().isEmpty) return const {};
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
