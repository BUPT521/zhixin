import '../application/evidence_service.dart';
import '../domain/models/evidence.dart';
import '../domain/models/search.dart';
import '../domain/rules/search_fusion.dart';

/// 查找请求的先后编号：快速切换查询或筛选时，只让最后一次请求写入页面。
class SearchRequestGate {
  int _current = 0;

  int start() => ++_current;

  bool isCurrent(int request) => request == _current;
}

/// 用户主动检索的结果；一条学习记录占一个 [SearchEntry]，材料页按页各占一个。
///
/// 查找范围单独记录：用户可以在全部记录、一个目标或一份材料里查找，这个
/// 选择只影响本次查找，不改变回答时使用的范围。
class SearchResults {
  const SearchResults({
    required this.query,
    this.scope = const EvidenceScope.userAll(),
    this.entries = const [],
    this.hasMore = false,
    this.nextOffset = 0,
  });

  final String query;
  final EvidenceScope scope;
  final List<SearchEntry> entries;

  /// 还有更早的命中没有取回；调用方用 [SearchService.searchPage] 继续翻页。
  final bool hasMore;

  /// 下一页从融合后的第几条记录开始。
  final int nextOffset;

  bool get isEmpty => entries.isEmpty;

  /// 接上下一页：按记录键去重，已经显示过的记录不再重复出现。
  SearchResults append(SearchResults next) {
    final seen = <String>{};
    return SearchResults(
      query: next.query.isEmpty ? query : next.query,
      scope: next.scope,
      entries: [
        for (final entry in [...entries, ...next.entries])
          if (seen.add(entry.key)) entry,
      ],
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
    );
  }
}

/// 记录页的本地检索：不联网也能完成，覆盖讨论消息、题目、已提交作答与材料页。
///
/// 用户查找先读全部命中再排序与去重，不按来源类别预先截断；[searchPage] 在
/// 按学习记录去重之后分页，翻页时再向后读取候选，较早的命中也能取到。带语义
/// 命中时本地候选固定读 [fusionWindow] 条，融合后从同一份结果里切片，翻页
/// 不会重复或漏项。
class SearchService {
  SearchService({required this.evidence});

  final EvidenceService evidence;

  static const int defaultPageSize = 20;

  /// 带语义命中时本地候选的固定窗口；超过这个条数的更早记录不进入本次融合。
  static const int fusionWindow = 2000;

  Future<SearchResults> search(
    String query, {
    EvidenceScope scope = const EvidenceScope.userAll(),
  }) async {
    final bundle = await evidence.userSearch(query, scope: scope, limit: null);
    return _results(
      query,
      scope,
      _entries(bundle.hits),
      hasMore: false,
      nextOffset: 0,
    );
  }

  /// 取去重后的第 [offset] 条学习记录起的一页；[hasMore] 表示后面还有命中。
  ///
  /// [semanticHits] 为空时按原来的窗口与放大逻辑读取，行为与没有语义检索时
  /// 一致。传入语义命中时本地候选固定读 [fusionWindow] 条，与语义命中按名次
  /// 融合后再切片；`nextOffset` 数的是融合后的记录数。
  Future<SearchResults> searchPage(
    String query, {
    EvidenceScope scope = const EvidenceScope.userAll(),
    int offset = 0,
    int pageSize = defaultPageSize,
    List<EvidenceHit> semanticHits = const [],
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchResults(query: '', scope: scope);
    }
    if (semanticHits.isNotEmpty) {
      final window = await evidence.userSearchWindow(
        trimmed,
        scope: scope,
        maxHits: fusionWindow,
      );
      final fused = fuseSearch(_entries(window.hits), semanticHits);
      final page = fused.skip(offset).take(pageSize).toList(growable: false);
      return _results(
        window.query,
        scope,
        page,
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
        return _results(
          window.query,
          scope,
          page,
          hasMore: filled || window.more,
          nextOffset: offset + page.length,
        );
      }
      maxHits *= 4;
    }
  }

  SearchResults _results(
    String query,
    EvidenceScope scope,
    List<SearchEntry> entries, {
    required bool hasMore,
    required int nextOffset,
  }) {
    return SearchResults(
      query: query,
      scope: scope,
      entries: entries,
      hasMore: hasMore,
      nextOffset: nextOffset,
    );
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
