import '../data/db/write_transactions.dart';
import '../data/revisions/revision_actions.dart';
import '../data/revisions/revision_models.dart';
import '../data/revisions/revision_service.dart';
import '../data/repository/schedule_repository.dart';
import '../data/repository/study_plan_repository.dart';
import '../data/repository/task_repository.dart';
import '../domain/models/study.dart';
import '../domain/models/study_plan.dart';
import 'service_runtime.dart';

/// 一份系统学习计划的摘要：下一步与最近一次预约，给日程页直接展示。
class StudyPlanSummary {
  const StudyPlanSummary({required this.plan, this.nextStep, this.nextBlock});

  final StudyPlan plan;
  final PlanItem? nextStep;
  final ScheduleBlock? nextBlock;
}

/// 安排页的一周日程与相关学习计划、事项、目标和可撤销的写入。
class PlanWeek {
  const PlanWeek({
    required this.timetable,
    required this.blocks,
    required this.items,
    required this.operations,
    this.goals = const [],
    this.studyPlans = const [],
    this.doneItemCount = 0,
  });

  final List<TimetableEntry> timetable;
  final List<ScheduledItem> blocks;

  /// 未完成的学习事项；已完成事项按页另读，不随这一份一起读回。
  final List<PlanItem> items;

  /// 已完成事项总数，界面据此提供“显示已完成（N）”与是否还有下一页。
  final int doneItemCount;

  /// 还没有撤销的 AI 写入与接受建议，界面按提交撤销。
  final List<RevisionCommit> operations;
  final List<StudyPlanSummary> studyPlans;

  /// 全部目标，当前有效的排在前面；可以同时有多个。
  final List<LearningGoal> goals;

  LearningGoal? goalById(int? id) {
    if (id == null) return null;
    return goals.where((goal) => goal.id == id).firstOrNull;
  }
}

/// 计划与日程：课表、学习事项、目标、时间块与撤销。
class PlanService {
  PlanService({
    required this.tasks,
    required this.schedule,
    required this.revisions,
    required this.runtime,
    required this.studyPlans,
    required this.transactions,
  });

  final TaskRepository tasks;
  final ScheduleRepository schedule;

  /// 回执与撤销都读提交历史，不再维护单独的操作日志。
  final RevisionService revisions;
  final ServiceRuntime runtime;
  final WriteTransactions transactions;

  /// 学习事项属于系统学习计划时，状态改动后同步计划的继续位置。
  final StudyPlanRepository studyPlans;

  /// 读取一份安排：本周课表、预约、未完成事项、目标、计划摘要与可撤销回执。
  ///
  /// 各段之间没有依赖，全部同时发出，页面等的是其中最慢的一段，而不是各段之和。
  /// 回执用一条查询按动作与表筛选，不再为每条可撤销提交再读一次变更明细。
  ///
  /// 已完成事项只读一个总数，不随打开安排页读回；用户展开“已完成”时再按页读。
  /// 系统学习的步骤另按未完成计划读取，既包含步骤里的已完成项，也不经事项列表
  /// 整体带入；已完成计划的步骤不再读回，进度由计划行的计数带出。
  Future<PlanWeek> loadWeek(DateTime anchor) async {
    final current = runtime.policy;
    final range = current.naturalWeekRange(anchor);
    final (
      items,
      plans,
      timetable,
      blocks,
      receipts,
      goals,
      doneCount,
    ) = await (
      tasks.items(openOnly: true),
      studyPlans.list(),
      schedule.timetable(),
      schedule.blocksBetween(range.start, range.endExclusive),
      _receipts(),
      tasks.goals(),
      tasks.countDone(),
    ).wait;

    // 已完成计划的步骤页面用不到：进度由计划行的计数带出，下一步始终为空，
    // 只按未完成计划读取步骤。
    final steps = await studyPlans.stepsForPlans(
      plans.where((plan) => !plan.done).map((plan) => plan.id),
    );
    final stepsByPlan = <int, List<PlanItem>>{};
    for (final step in steps) {
      final planId = step.studyPlanId;
      if (planId == null) continue;
      stepsByPlan.putIfAbsent(planId, () => []).add(step);
    }
    final nextBlocks = await schedule.nextBlocksForItems(
      steps.where((step) => step.open).map((step) => step.id),
      current.now,
    );
    final summaries = <StudyPlanSummary>[];
    for (final plan in plans) {
      final ordered = [...?stepsByPlan[plan.id]]
        ..sort((a, b) {
          final left = a.seq ?? 0;
          final right = b.seq ?? 0;
          return left.compareTo(right);
        });
      ScheduleBlock? nextBlock;
      for (final step in ordered.where((step) => step.open)) {
        final block = nextBlocks[step.id];
        if (block == null) continue;
        if (nextBlock == null || block.startAt.isBefore(nextBlock.startAt)) {
          nextBlock = block;
        }
      }
      summaries.add(
        StudyPlanSummary(
          plan: plan,
          nextStep: currentStudyStep(ordered),
          nextBlock: nextBlock,
        ),
      );
    }
    return PlanWeek(
      timetable: timetable,
      blocks: blocks,
      items: items,
      operations: receipts,
      goals: goals,
      studyPlans: summaries,
      doneItemCount: doneCount,
    );
  }

  /// 已完成事项按页读取；安排页展开“已完成”时逐页调用。
  Future<List<PlanItem>> doneItems({int limit = 30, int offset = 0}) =>
      tasks.doneItems(limit: limit, offset: offset);

  /// 按编号读一项事项；周视图点到的预约可能不在本页读回的事项里。
  Future<PlanItem?> itemById(int id) => tasks.byId(id);

  /// 安排页只展示真正写入了记忆或学习事项的提交；只有卡片状态变化、没有
  /// 数据写入的提交不算改动。其他写入在数据版本页按完整历史查看。
  ///
  /// 不截断较早的回执：库里已有的改动都能在安排页找到撤销入口。
  Future<List<RevisionCommit>> _receipts() => revisions.receiptCommits(
    actions: receiptActions,
    tables: const {'memory', 'plan_item'},
  );

  /// 新建事项只写用户明确选择的归属与一段说明；没有选择时就不归属任何目标。
  Future<int> addItem({
    required String title,
    int? goalId,
    String? note,
    DateTime? dueAt,
    int? minutes,
  }) {
    return tasks.createItem(
      title: title,
      goalId: goalId,
      note: note,
      dueAt: dueAt,
      estMinutes: minutes,
    );
  }

  Future<int> addGoal({
    required String title,
    String? scopeText,
    DateTime? dueDate,
  }) {
    return tasks.createGoal(
      title: title,
      scopeText: scopeText,
      dueDate: dueDate,
    );
  }

  /// 暂停目标；取消弹性安排与目标状态在同一条提交里，要么都写，要么都不写。
  ///
  /// 待取消的预约在事务内按目标重新读取，再用一条语句一起取消，最后才改目标
  /// 状态；中途失败时这次事务整体回滚，不会留下已经取消的预约与仍在进行中的
  /// 目标。
  Future<int?> pauseGoal(int id, {bool cancelFlexibleFuture = false}) {
    final now = runtime.policy.now;
    return transactions.run((txn) async {
      if (cancelFlexibleFuture) {
        final blocks = await schedule.flexibleFutureBlocksForGoal(
          id,
          now,
          executor: txn.executor,
        );
        await schedule.cancelBlocks(
          blocks.map((block) => block.id),
          executor: txn.executor,
        );
      }
      await tasks.pauseGoal(id, transaction: txn);
      return txn.requireCommitId();
    }, label: '暂停目标');
  }

  Future<void> resumeGoal(int id) {
    return transactions.run(
      (txn) => tasks.resumeGoal(id, transaction: txn),
      label: '恢复目标',
    );
  }

  Future<void> closeGoal(int id) {
    return transactions.run(
      (txn) => tasks.closeGoal(id, transaction: txn),
      label: '结束目标',
    );
  }

  /// 目标下未开始的弹性安排数量，暂停前用于说明会取消什么。
  Future<int> flexibleFutureCount(int goalId) async {
    final blocks = await schedule.flexibleFutureBlocksForGoal(
      goalId,
      runtime.policy.now,
    );
    return blocks.length;
  }

  Future<void> setStatus(int id, PlanItemStatus status) async {
    await studyPlans.setItemStatus(id, status);
  }

  Future<void> setPriority(int id, int priority) =>
      tasks.setPriority(id, priority);

  /// 为一项安排一次时间；返回提交编号，界面据此提供撤销。
  ///
  /// 单条预约原先只写时间块，不回到提示条，也不出现在提交历史之外的入口；
  /// 现在与整组顺延一样在事务里写入并带回编号，撤销时按提交回放。
  Future<int> scheduleItem({
    required int planItemId,
    required DateTime start,
    required DateTime end,
    String source = 'user',
  }) {
    return transactions.run((txn) async {
      await schedule.addBlock(
        planItemId: planItemId,
        start: start,
        end: end,
        source: source,
        executor: txn.executor,
      );
      return txn.requireCommitId();
    }, label: '安排学习时间');
  }

  /// 改一次预约的时间；与单条预约一样返回提交编号。
  Future<int> moveBlock(
    int id, {
    required DateTime start,
    required DateTime end,
  }) {
    return transactions.run((txn) async {
      await schedule.moveBlock(
        id,
        start: start,
        end: end,
        executor: txn.executor,
      );
      return txn.requireCommitId();
    }, label: '调整预约时间');
  }

  /// 一次业务动作调整多条预约；要么全部写入，要么整组保持原样。
  ///
  /// 返回这次写入的提交编号，界面据此提供撤销，不再从提交历史里取最近一条：
  /// 取到的可能不是这次调整，撤销就成了别的动作。
  Future<int> rescheduleGroup(List<ScheduleAdjustment> adjustments) {
    return transactions.run(
      (txn) async {
        await schedule.rescheduleGroup(adjustments, executor: txn.executor);
        return txn.requireCommitId();
      },
      label: '调整多个预约',
      actor: 'user',
    );
  }

  /// 取消、恢复、固定与删除预约各自形成一次可撤销的提交。
  Future<int> setBlockStatus(int id, String status) {
    return transactions.run((txn) async {
      await schedule.setBlockStatus(id, status, executor: txn.executor);
      return txn.requireCommitId();
    }, label: '修改预约状态');
  }

  Future<int> deleteBlock(int id) {
    return transactions.run((txn) async {
      await schedule.deleteBlock(id, executor: txn.executor);
      return txn.requireCommitId();
    }, label: '删除预约');
  }

  Future<int> setBlockLocked(int id, bool locked) {
    return transactions.run((txn) async {
      await schedule.setLocked(id, locked, executor: txn.executor);
      return txn.requireCommitId();
    }, label: locked ? '固定这次预约' : '改为弹性预约');
  }

  Future<void> addTimetable({
    required int weekday,
    required String startTime,
    required String endTime,
    required String title,
    String? location,
  }) {
    return schedule.addTimetable(
      weekday: weekday,
      startTime: startTime,
      endTime: endTime,
      title: title,
      location: location,
    );
  }

  /// 删除一节课；返回提交编号，提示条据此提供撤销。
  Future<int> deleteTimetable(int id) {
    return transactions.run((txn) async {
      await schedule.deleteTimetable(id, executor: txn.executor);
      return txn.requireCommitId();
    }, label: '删除课表');
  }

  /// 当前时刻之后最近的一个时间块，给首页“接下来”用。
  Future<ScheduledItem?> nextBlock() => schedule.nextAfter(runtime.policy.now);
}
