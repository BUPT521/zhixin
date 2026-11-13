import 'evidence.dart';

/// 一条记录出现在查找结果里的原因；同一记录命中多路时按原样、关键词、语义的
/// 顺序取第一个，界面只区分有没有原样命中与是否只来自语义。
enum SearchReason { literal, keyword, semantic }

/// 一页里的一条记录：讨论、题目与作答按学习记录汇总，材料页按页各占一条。
///
/// [localRank] 是本地列表中的名次，[semanticRank] 是语义候选中的名次，两者都
/// 从 1 开始；缺少某一路时该路名次为空。融合分数按名次倒数相加，两路都命中
/// 的记录自然高于只被一路命中的记录。
class SearchEntry {
  const SearchEntry({
    required this.key,
    required this.hits,
    this.localRank,
    this.semanticRank,
  });

  /// `conversation:12` 或 `material_page:3:7`；同一条学习记录只占一个键。
  final String key;
  final List<EvidenceHit> hits;
  final int? localRank;
  final int? semanticRank;

  bool get hasLiteral => hits.any((hit) => hit.literal);

  SearchReason get reason {
    if (hasLiteral) return SearchReason.literal;
    if (hits.any((hit) => !hit.semantic)) return SearchReason.keyword;
    return SearchReason.semantic;
  }

  /// 只有语义一路找到这条记录；界面据此加“按意思”标签。
  bool get semanticOnly => reason == SearchReason.semantic;

  double get fusionScore => _rrf(localRank) + _rrf(semanticRank);

  SearchEntry withLocalRank(int rank) => SearchEntry(
    key: key,
    hits: hits,
    localRank: rank,
    semanticRank: semanticRank,
  );

  SearchEntry withSemanticRank(int rank) => SearchEntry(
    key: key,
    hits: hits,
    localRank: localRank,
    semanticRank: rank,
  );

  static double _rrf(int? rank) => rank == null ? 0 : 1 / (60 + rank);
}
