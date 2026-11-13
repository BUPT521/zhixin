import 'package:bm25/bm25.dart';

import '../domain/models/evidence.dart';
import '../domain/rules/chinese_tokens.dart';

/// 关键词候选的 BM25 排序。
///
/// 查询与原文都先经过 [bm25IndexText] 切词，避免中文整句只算一个词；排序只
/// 调整候选之间的先后，不丢掉题号、页码和原句的精确命中。返回结果保持原候选
/// 的来源标识，合并时仍然按标识去重。
Future<List<EvidenceHit>> rankKeywordCandidates(
  List<EvidenceHit> candidates,
  String query,
) async {
  if (candidates.length < 2) return candidates;
  final indexed = <String, EvidenceHit>{
    for (final hit in candidates) hit.identity: hit,
  };
  final docs = [for (final hit in indexed.values) bm25IndexText(hit.text)];
  final engine = await BM25.build(docs);
  try {
    final results = await engine.search(
      bm25IndexText(query),
      limit: docs.length,
    );
    final ordered = <EvidenceHit>[
      for (final result in results)
        if (result.doc.id >= 0 && result.doc.id < indexed.length)
          indexed.values.elementAt(result.doc.id),
    ];
    final seen = {for (final hit in ordered) hit.identity};
    ordered.addAll(indexed.values.where((hit) => !seen.contains(hit.identity)));
    return ordered;
  } finally {
    await engine.dispose();
  }
}

/// 合并精确命中与排序结果：字面命中固定在前，其余按 BM25 顺序，同一来源只
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
