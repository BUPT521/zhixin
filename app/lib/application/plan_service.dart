import '../data/db/write_transactions.dart';
import '../data/repository/study_plan_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/study.dart';
import '../domain/models/write_result.dart';
import '../../domain/rules/uuid_v7.dart';
import 'paged_result.dart';
import 'plan_search.dart';
import 'screen_tables.dart';
import 'service_runtime.dart';

/// 安排页的事项与目标。
class PlanOverview {
  const PlanOverview({
    required this.items,
    this.goals = const [],
    this.doneItemCount = 0,
  });

  final List<PlanItem> items;
  final List<LearningGoal> goals;
  final int doneItemCount;
}

class PlanService {
  PlanService({
    required this.tasks,
    required this.runtime,
    required this.studyPlans,
    required this.transactions,
  });

  final TaskRepository tasks;

  /// 全部目标，当前有效的排在前面；不能靠 [loadOverview] 的页面从这里读。
  Future<List<LearningGoal>> goals() => tasks.goals();

  Stream<PlanOverview> watchOverview() =>
      runtime.watch(tables: ScreenTables.planOverview, read: loadOverview);

  /// 跟随写入更新的目标列表；归属选择与筛选条用它。
  Stream<List<LearningGoal>> watchGoals() =>
      runtime.watch(tables: ScreenTables.goals, read: goals);

  /// 跟随写入更新的已完成事项分页；展开列表之后每页都是一个订阅。
  Stream<List<PlanItem>> watchDoneItems({int limit = 30, int offset = 0}) =>
      runtime.watch(
        tables: ScreenTables.planItems,
        read: () => doneItems(limit: limit, offset: offset),
      );

  /// 当前有效的目标；记录检索与记忆建议的归属选择从这里读。
  Future<List<LearningGoal>> activeGoals() => tasks.activeGoals();

  final ServiceRuntime runtime;
  final WriteTransactions transactions;

  /// 学习事项属于系统学习计划时，状态改动后同步计划的继续位置。
  final StudyPlanRepository studyPlans;

  Future<PlanOverview> loadOverview() async {
    final (items, goals, doneCount) = await (
      tasks.items(openOnly: true),
      tasks.goals(),
      tasks.countDone(),
    ).wait;
    return PlanOverview(items: items, goals: goals, doneItemCount: doneCount);
  }

  /// 已完成事项按页读取；安排页展开“已完成”时逐页调用。
  Future<List<PlanItem>> doneItems({int limit = 30, int offset = 0}) =>
      tasks.doneItems(limit: limit, offset: offset);

  /// 按标题、说明、目标、状态和截止日期查找事项。
  Future<PagedResult<PlanSearchHit>> searchPage(
    PlanSearchQuery query, {
    int offset = 0,
    int pageSize = kSearchPageSize,
  }) async {
    if (query.isEmpty) return const PagedResult<PlanSearchHit>();
    final day = query.day;
    final range = day == null ? null : runtime.policy.naturalDayRange(day);
    final items = await tasks.searchItems(
      goalId: query.goalId,
      status: query.status,
      dayStart: range?.start,
      dayEnd: range?.endExclusive,
    );
    final hits = <PlanSearchHit>[
      for (final item in items)
        if (planSearchMatches(
          query.keyword,
          title: item.title,
          note: item.note,
        ))
          PlanSearchHit.item(item),
    ];
    return pagePlanSearchHits(hits, offset: offset, pageSize: pageSize);
  }

  /// 按编号读一项事项。
  Future<PlanItem?> itemById(String id) => tasks.byId(id);

  /// 新建事项只写用户明确选择的归属与一段说明；没有选择时就不归属任何目标。
  ///
  /// 编号按草稿内容生成，同一份草稿连点两次只形成一条提交。
  Future<WriteResult> addItem({
    required String title,
    String? goalId,
    String? note,
    DateTime? dueAt,
    int? minutes,
  }) {
    return transactions.run(
      (txn) async {
        await tasks.createItem(
          title: title,
          goalId: goalId,
          note: note,
          dueAt: dueAt,
          estMinutes: minutes,
          transaction: txn,
        );
        return txn.result();
      },
      label: '新建学习事项',
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  /// 新建目标；编号按标题、范围与截止日期生成，同一份草稿连点两次只写一次。
  Future<WriteResult> addGoal({
    required String title,
    String? scopeText,
    DateTime? dueDate,
  }) {
    return transactions.run(
      (txn) async {
        await tasks.createGoal(
          title: title,
          scopeText: scopeText,
          dueDate: dueDate,
          transaction: txn,
        );
        return txn.result();
      },
      label: '新建目标',
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  Future<WriteResult> pauseGoal(String id) => transactions.run(
    (txn) async {
      await tasks.pauseGoal(id, transaction: txn);
      return txn.result();
    },
    label: '暂停目标',
    uid: newUuidV7(),
    onDuplicate: (commit) => WriteResult.committed(commit.id),
  );

  Future<WriteResult> resumeGoal(String id) {
    return transactions.run(
      (txn) async {
        await tasks.resumeGoal(id, transaction: txn);
        return txn.result();
      },
      label: '恢复目标',
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  Future<WriteResult> closeGoal(String id) {
    return transactions.run(
      (txn) async {
        await tasks.closeGoal(id, transaction: txn);
        return txn.result();
      },
      label: '结束目标',
      uid: newUuidV7(),
      onDuplicate: (commit) => WriteResult.committed(commit.id),
    );
  }

  /// 完成、改回或暂停一个事项；事务内先看当前状态，已经是目标状态时直接跳过，
  /// 同一按钮连点两次只形成一条提交。
  ///
  /// 状态迁移不用请求编号去重：同一个目标状态可能被多次进入（完成后改回、
  /// 再完成），按编号去重会把后续动作误判成重试；重试的判定交给事务内的
  /// 状态比对。
  Future<WriteResult> setStatus(String id, PlanItemStatus status) =>
      transactions.run((txn) async {
        final current = await tasks.byId(id, transaction: txn);
        if (current == null) return const WriteResult.skipped('这项事项已不存在');
        if (current.status == status) {
          return const WriteResult.skipped('事项已经是这个状态');
        }
        await studyPlans.setItemStatus(id, status, transaction: txn);
        return txn.result();
      }, label: '更新事项状态');

  Future<WriteResult> setPriority(String id, int priority) => transactions.run(
    (txn) async {
      await tasks.setPriority(id, priority, transaction: txn);
      return txn.result();
    },
    label: '调整事项优先级',
    uid: newUuidV7(),
    onDuplicate: (commit) => WriteResult.committed(commit.id),
  );
}
