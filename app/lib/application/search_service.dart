import '../application/evidence_service.dart';
import '../domain/models/evidence.dart';
import '../domain/models/search.dart';
import '../domain/rules/search_fusion.dart';
import 'paged_result.dart';

/// 记录页的本地检索：不联网也能完成，覆盖讨论消息、题目、已提交作答与材料页。
///
/// 用户查找先读全部命中再排序与去重，不按来源类别预先截断；[searchPage] 在
/// 按学习记录去重之后分页，翻页时再向后读取候选，较早的命中也能取到。带索引
/// 命中时本地候选只取字面命中，索引给出的关键词与语义候选由调用方传入，同一
/// 批命中只参与一次融合；本地窗口固定读 [fusionWindow] 条，融合后从同一份
/// 结果里切片，翻页不会重复或漏项。
class SearchService {
  SearchService({required this.evidence});

  final EvidenceService evidence;

  /// 带索引命中时字面候选的固定窗口；超过这个条数的更早记录不进入本次融合。
  static const int fusionWindow = 2000;

  /// 取去重后的第 [offset] 条学习记录起的一页；[PagedResult.hasMore] 表示后面
  /// 还有命中。
  ///
  /// [semanticHits] 为空时先读本地窗口再按需扩大，与只有字面检索时一致，索引
  /// 候选由 [EvidenceService.userSearchWindow] 一并取回。传入索引命中时本地
  /// 窗口只取字面，关键词与语义候选不再重复读取，融合之后再切片；`nextOffset`
  /// 数的是融合后的记录数。
  Future<PagedResult<SearchEntry>> searchPage(
    String query, {
    EvidenceScope scope = const EvidenceScope.userAll(),
    int offset = 0,
    int pageSize = kSearchPageSize,
    List<EvidenceHit> semanticHits = const [],
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const PagedResult<SearchEntry>();
    if (semanticHits.isNotEmpty) {
      final window = await evidence.userSearchWindow(
        trimmed,
        scope: scope,
        maxHits: fusionWindow,
        includeIndex: false,
      );
      final fused = fuseSearch(_entries(window.hits), semanticHits);
      final page = fused.skip(offset).take(pageSize).toList(growable: false);
      return PagedResult(
        items: page,
        hasMore: offset + page.length < fused.length,
        nextOffset: offset + page.length,
      );
    }
    var maxHits = 800;
    while (true) {
      final window = await evidence.userSearchWindow(
        trimmed,
        scope: scope,
        maxHits: maxHits,
      );
      final entries = _entries(window.hits);
      final filled = entries.length > offset + pageSize;
      if (filled || !window.more || maxHits >= 6400) {
        final page = entries.skip(offset).take(pageSize).toList();
        return PagedResult(
          items: page,
          hasMore: filled || window.more,
          nextOffset: offset + page.length,
        );
      }
      maxHits *= 4;
    }
  }

  /// 按学习记录去重：同一条记录的题目、消息与作答只占一个位置，消息只保留
  /// 相关性最高的一条。材料页各自占一个位置。传入的命中已按相关性排好序，
  /// 因此第一次出现的记录就是这一页的先后顺序。
  static List<SearchEntry> _entries(List<EvidenceHit> hits) {
    final index = <String, SearchEntry>{};
    final order = <String>[];
    for (final hit in hits) {
      final key = searchEntryKey(hit);
      final entry = index[key];
      if (entry == null) {
        index[key] = SearchEntry(
          key: key,
          hits: [hit],
          localRank: order.length + 1,
        );
        order.add(key);
        continue;
      }
      if (hit.kind == EvidenceKind.message &&
          entry.hits.any((item) => item.kind == EvidenceKind.message)) {
        continue;
      }
      entry.hits.add(hit);
    }
    return [for (final key in order) index[key]!];
  }
}
