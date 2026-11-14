import '../domain/models/evidence.dart';

/// 关键词候选的先后与合并。
///
/// 排序已经在索引里做完了：仓库层的 `MATCH` 按 `bm25()` 取候选，调用方拿到的
/// 就是按相关性排好的结果。这里只把名次折成分数，并负责与字面命中合并，
/// 不再在内存里重建索引（ADR-0013）。
List<EvidenceHit> scoreKeywordCandidates(List<EvidenceHit> candidates) {
  if (candidates.isEmpty) return candidates;
  return [
    for (var index = 0; index < candidates.length; index++)
      candidates[index].copyWith(score: 40 - index * 0.1),
  ];
}

/// 合并精确命中与排序结果：字面命中固定在前，其余按关键词顺序，同一来源只
/// 保留一条。
List<EvidenceHit> mergeExactAndRanked(
  Iterable<EvidenceHit> exact,
  Iterable<EvidenceHit> ranked,
) {
  final merged = <String, EvidenceHit>{};
  for (final hit in exact) {
    merged.putIfAbsent(hit.identity, () => hit);
  }
  for (final hit in ranked) {
    merged.putIfAbsent(hit.identity, () => hit);
  }
  return merged.values.toList(growable: false);
}
