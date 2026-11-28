/// 查找一页的条数：记录、安排、记忆与材料查找都取这一档，各页与服务层不再
/// 自己写一个 20。
const int kSearchPageSize = 20;

/// 一页查找结果：条目、后面还有没有与下一页起点。
///
/// 记录、安排、记忆与材料查找都返回这一份：查询条件留在页面或服务自己的类型
/// 里，这一份只保留分页需要的字段，追加与去重的规则也只由 [append] 提供。
class PagedResult<T> {
  const PagedResult({
    this.items = const [],
    this.hasMore = false,
    this.nextOffset = 0,
    this.total,
  });

  /// 这一页的条目。
  final List<T> items;

  /// 后面还有没有命中。
  final bool hasMore;

  /// 下一页从第几条开始。
  final int nextOffset;

  /// 本次条件命中的总数；服务不知道时为空。
  final int? total;

  bool get isEmpty => items.isEmpty;

  int get length => items.length;

  /// 接上下一页：给出 [key] 时按它去重，已经出现过的条目不重复追加；
  /// 不给 [key] 时直接接上，由调用方保证两页不重叠。
  PagedResult<T> append(PagedResult<T> next, {Object? Function(T item)? key}) {
    if (key == null) {
      return PagedResult<T>(
        items: [...items, ...next.items],
        hasMore: next.hasMore,
        nextOffset: next.nextOffset,
        total: next.total ?? total,
      );
    }
    final seen = <Object?>{};
    return PagedResult<T>(
      items: [
        for (final item in [...items, ...next.items])
          if (seen.add(key(item))) item,
      ],
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
      total: next.total ?? total,
    );
  }

  /// [PagedResult] 不可变；[append] 返回新的一份，正在读的旧页不受影响。
  @override
  String toString() =>
      'PagedResult(items: ${items.length}, hasMore: $hasMore, '
      'nextOffset: $nextOffset, total: $total)';
}
