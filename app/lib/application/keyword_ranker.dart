import '../domain/models/evidence.dart';

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
