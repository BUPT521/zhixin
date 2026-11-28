import '../data/repository/material_repository.dart';
import '../domain/models/material.dart';
import '../domain/rules/search_terms.dart';
import 'paged_result.dart';

/// 材料查找命中的原因；一次命中只写最靠前的一条。
///
/// 标题与来源属于材料本身，页标签与正文属于某一页；同一份材料同时命中时
/// 按这个顺序取，列表里写出的原因因此稳定。
enum MaterialMatchKind { title, source, pageLabel, pageContent }

/// 一条材料命中：哪一份材料、因为什么命中，页码与摘要只在页内命中时有值。
class MaterialMatch {
  const MaterialMatch({
    required this.material,
    required this.kind,
    this.pageNo,
    this.pageLabel,
    this.snippet,
  });

  final Material material;
  final MaterialMatchKind kind;
  final int? pageNo;
  final String? pageLabel;

  /// 页内正文命中的原文片段；标题、来源与页标签命中时为空。
  final String? snippet;

  /// 列表里写出的命中原因；页内命中带页码，Word 材料按片段称呼。
  String get reason => switch (kind) {
    MaterialMatchKind.title => '标题命中',
    MaterialMatchKind.source => '来源命中',
    MaterialMatchKind.pageLabel => '${material.position(pageNo)}的标签命中',
    MaterialMatchKind.pageContent => '${material.position(pageNo)}的正文命中',
  };
}

/// 材料列表与材料选择器共用的本地查找。
///
/// 不调用模型：标题、来源、页标签与页内正文都在本机查，断网与没有配置模型
/// 时照样可用。结果按材料列表的顺序分页，因此命中超过一页时继续加载仍能翻到
/// 最早一条；查询与筛选变化后的旧结果由页面的请求编号丢弃，不在服务层排队。
/// 材料详情只在已经读到的页面正文里定位，不经过这里。
class MaterialSearchService {
  MaterialSearchService({required this.materials});

  final MaterialRepository materials;

  /// 取第 [offset] 条起的一页命中；[PagedResult.hasMore] 表示后面还有。
  Future<PagedResult<MaterialMatch>> searchPage(
    String query, {
    int offset = 0,
    int pageSize = kSearchPageSize,
  }) async {
    final text = query.trim();
    if (text.isEmpty || pageSize <= 0) {
      return const PagedResult<MaterialMatch>();
    }
    // 多取一条用来判断后面还有没有，不必再查一次总数。
    final rows = await materials.search(
      text,
      limit: pageSize + 1,
      offset: offset,
    );
    final hasMore = rows.length > pageSize;
    final page = hasMore ? rows.sublist(0, pageSize) : rows;
    return PagedResult(
      items: [for (final row in page) _match(text, row)],
      hasMore: hasMore,
      nextOffset: offset + page.length,
    );
  }

  /// 一行命中原因：材料本身先看标题、再看来源，之后才是命中页的标签与正文。
  MaterialMatch _match(String query, MaterialSearchRow row) {
    final material = row.material;
    if (literalMatchIndex(material.title, query) >= 0) {
      return MaterialMatch(material: material, kind: MaterialMatchKind.title);
    }
    final sourceRef = material.sourceRef;
    if (sourceRef != null && literalMatchIndex(sourceRef, query) >= 0) {
      return MaterialMatch(material: material, kind: MaterialMatchKind.source);
    }
    final pageNo = row.pageNo;
    if (pageNo != null) {
      final label = row.pageLabel;
      if (label != null && literalMatchIndex(label, query) >= 0) {
        return MaterialMatch(
          material: material,
          kind: MaterialMatchKind.pageLabel,
          pageNo: pageNo,
          pageLabel: label,
        );
      }
      final content = row.pageContent ?? '';
      return MaterialMatch(
        material: material,
        kind: MaterialMatchKind.pageContent,
        pageNo: pageNo,
        pageLabel: label,
        snippet: searchSnippet(content, [query], limit: 80),
      );
    }
    // 查询条件保证材料要么标题、来源命中，要么带回命中的一页；走到这里时
    // 仍按标题命中显示，不把这一条从结果里丢掉。
    return MaterialMatch(material: material, kind: MaterialMatchKind.title);
  }
}
