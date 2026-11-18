/// 安排查找的条件、命中与分页规则（docs/02 第 3.14 节、V10）。
///
/// 查找覆盖学习事项（含系统学习步骤）与预约：关键词匹配事项标题与说明，
/// 目标按 `goalId`、状态按 [PlanItemStatus] 筛，日期用同一个自然日区间同时
/// 筛事项截止时间与预约开始时间。全部读取本机库，不调用模型与网络。
library;

import '../domain/models/study.dart';
import '../domain/rules/search_terms.dart';

/// 安排查找一页的条数；记录页查找同样是二十条一页。
const int planSearchPageSize = 20;

/// 一次安排查找的条件；全部为空时页面只显示入口提示，不发起查询。
class PlanSearchQuery {
  const PlanSearchQuery({
    this.keyword = '',
    this.goalId,
    this.status,
    this.day,
  });

  /// 关键词；按 [planSearchMatches] 的规则匹配事项标题与说明。
  final String keyword;

  /// 目标筛选；为空表示全部目标。
  final String? goalId;

  /// 状态筛选；为空表示全部状态。
  final PlanItemStatus? status;

  /// 日期筛选的自然日；为空表示全部日期。
  final DateTime? day;

  bool get isEmpty =>
      keyword.trim().isEmpty && goalId == null && status == null && day == null;

  @override
  bool operator ==(Object other) =>
      other is PlanSearchQuery &&
      other.keyword == keyword &&
      other.goalId == goalId &&
      other.status == status &&
      other.day == day;

  @override
  int get hashCode => Object.hash(keyword, goalId, status, day);
}

/// 关键词是否命中一份事项：按空白与标点切词，每一段都出现在标题或说明里。
///
/// 切词沿用本地检索的 [searchTerms]，与记录页的关键词规则是同一份；拉丁字母
/// 不区分大小写，中文按原样比对。关键词为空时视为命中，由调用方决定是否按
/// 其他筛选条件查询。
bool planSearchMatches(String keyword, {required String title, String? note}) {
  final terms = searchTerms(keyword.trim());
  if (terms.isEmpty) return true;
  final haystack = (note == null ? title : '$title\n$note').toLowerCase();
  return terms.every((term) => haystack.contains(term.toLowerCase()));
}

/// 一条查找结果：事项本身，或它的一次预约。
///
/// 预约命中时只带预约与所属事项的摘要，打开之前按 [planItemId] 补读整条
/// 事项：继续位置规则由 `openPlanItem` 决定，这里不另存一份判断。
class PlanSearchHit {
  const PlanSearchHit.item(PlanItem this.item) : scheduled = null;
  const PlanSearchHit.block(ScheduledItem this.scheduled) : item = null;

  final PlanItem? item;
  final ScheduledItem? scheduled;

  bool get isBlock => scheduled != null;

  /// 结果在列表里的唯一键：同一事项的两次预约各占一条。
  String get id =>
      isBlock ? 'block:${scheduled!.block.id}' : 'item:${item!.id}';

  String get planItemId => isBlock ? scheduled!.block.planItemId : item!.id;

  String get title => isBlock ? scheduled!.itemTitle : item!.title;

  String? get note => isBlock ? scheduled!.itemNote : item!.note;

  PlanItemStatus get status => isBlock ? scheduled!.itemStatus : item!.status;

  /// 排序与展示用的一次时间：预约取开始时间，事项取截止时间。
  DateTime? get at => isBlock ? scheduled!.block.startAt : item!.dueAt;
}

/// 一页安排查找结果；还有更早的命中时按 [nextOffset] 继续读。
class PlanSearchPageResult {
  const PlanSearchPageResult({
    required this.query,
    this.hits = const [],
    this.hasMore = false,
    this.nextOffset = 0,
  });

  final PlanSearchQuery query;
  final List<PlanSearchHit> hits;
  final bool hasMore;
  final int nextOffset;

  bool get isEmpty => hits.isEmpty;

  /// 接上下一页：同一个键的结果只保留一次，与记录页查找的追加规则一致。
  PlanSearchPageResult append(PlanSearchPageResult next) {
    final seen = {for (final hit in hits) hit.id};
    return PlanSearchPageResult(
      query: next.query,
      hits: [
        for (final hit in [...hits, ...next.hits])
          if (seen.add(hit.id)) hit,
      ],
      hasMore: next.hasMore,
      nextOffset: next.nextOffset,
    );
  }
}

/// 最终顺序：有时间的结果按时间从晚到早，没有时间的排在最后，同一时刻按
/// 标题与编号定序。分页在这个总顺序上切片，翻页因此不会重复或漏掉最早的
/// 一条（V10）。
int comparePlanSearchHits(PlanSearchHit a, PlanSearchHit b) {
  final left = a.at;
  final right = b.at;
  if (left != null && right != null) {
    final byTime = right.compareTo(left);
    if (byTime != 0) return byTime;
  } else if (left != null) {
    return -1;
  } else if (right != null) {
    return 1;
  }
  final byTitle = a.title.compareTo(b.title);
  if (byTitle != 0) return byTitle;
  return a.id.compareTo(b.id);
}

/// 把候选排成最终顺序，切出第 [offset] 条起的一页。
PlanSearchPageResult pagePlanSearchHits(
  PlanSearchQuery query,
  List<PlanSearchHit> hits, {
  required int offset,
  required int pageSize,
}) {
  if (offset < 0) throw ArgumentError.value(offset, 'offset', '不能为负数');
  if (pageSize <= 0) throw ArgumentError.value(pageSize, 'pageSize', '要大于零');
  final sorted = [...hits]..sort(comparePlanSearchHits);
  final page = sorted.skip(offset).take(pageSize).toList(growable: false);
  return PlanSearchPageResult(
    query: query,
    hits: page,
    hasMore: offset + page.length < sorted.length,
    nextOffset: offset + page.length,
  );
}

/// 查找入口的读法：页面默认走安排服务的 `searchPage`，测试可以换一份。
typedef PlanSearchRunner = Future<PlanSearchPageResult> Function(
  PlanSearchQuery query, {
  int offset,
});
