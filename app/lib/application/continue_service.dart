import '../data/repository/conversation_repository.dart';
import '../data/repository/study_plan_repository.dart';
import '../domain/models/study_plan.dart';

/// 首页“继续上次”的一条入口：一份进行中的计划或一条讨论。
///
/// 两类入口共用同一个时间键与同一个比较顺序，首页不再各排一套；有未提交
/// 草稿的讨论取草稿的保存时间，所以刚写下的草稿不会排到较早的计划后面。
class ContinueEntry {
  const ContinueEntry.plan(StudyPlan this.plan) : record = null;
  const ContinueEntry.conversation(ConversationRecord this.record)
    : plan = null;

  final StudyPlan? plan;
  final ConversationRecord? record;

  bool get isPlan => plan != null;
  bool get hasDraft => record?.hasDraft ?? false;

  /// 最近一次学习行为的时间；没有时间的入口排在有时间的入口之后。
  DateTime? get lastActiveAt => plan?.updatedAt ?? record?.lastActiveAt;

  int get _kindOrder => hasDraft ? 0 : (isPlan ? 1 : 2);
  int get _id => plan?.id ?? record!.id;
}

/// 读取首页的继续入口。
///
/// 进行中的系统学习计划与全部讨论一起按最近一次学习行为倒序排列，时间相同
/// 时未提交草稿优先，其次计划，最后讨论；页面只显示前几条，不再把计划和
/// 记录分成两段各自排序。
class ContinueService {
  ContinueService({required this.conversations, required this.plans});

  final ConversationRepository conversations;
  final StudyPlanRepository plans;

  Future<List<ContinueEntry>> load({int limit = 4}) async {
    if (limit <= 0) return const [];
    // 两类入口各自只读前 limit 条：全局前 limit 名一定在自己这一类的
    // 前 limit 名里，所以结果与读全库再排序相同，读取量只跟显示条数有关。
    // 两份读取互不依赖，同时发出，页面不必等前一份结束再发后一份。
    final (openPlans, records) = await (
      plans.listRecentlyAdvanced(limit: limit),
      conversations.listRecentlyActive(limit: limit),
    ).wait;
    final entries = <ContinueEntry>[
      for (final plan in openPlans)
        if (plan.open) ContinueEntry.plan(plan),
      for (final record in records) ContinueEntry.conversation(record),
    ];
    entries.sort(_byRecent);
    return entries.take(limit).toList(growable: false);
  }

  static int _byRecent(ContinueEntry left, ContinueEntry right) {
    final leftAt = left.lastActiveAt;
    final rightAt = right.lastActiveAt;
    if (leftAt != null && rightAt != null) {
      final byTime = rightAt.compareTo(leftAt);
      if (byTime != 0) return byTime;
    } else if (leftAt == null && rightAt != null) {
      return 1;
    } else if (leftAt != null && rightAt == null) {
      return -1;
    }
    final byKind = left._kindOrder.compareTo(right._kindOrder);
    return byKind != 0 ? byKind : right._id.compareTo(left._id);
  }
}
