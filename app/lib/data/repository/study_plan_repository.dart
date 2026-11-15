import 'dart:convert';

import '../../domain/models/material.dart';
import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/models/study_plan.dart';
import '../../domain/rules/study_plan_steps.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 系统学习计划与它的步骤（01 `study_plan` / `plan_item`）。
///
/// 计划保存材料范围、当前页码与状态；步骤本身就是学习事项，按 `seq` 排列，
/// 完成一步后继续位置前移。临时求助不改变计划位置，返回时按当前步骤继续。
/// 步骤的排程与完成状态和普通事项共用，不再另存一张生命周期表。
class StudyPlanRepository {
  StudyPlanRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<int> create({
    required String title,
    int? materialId,
    int? goalId,
    int? conversationId,
    int? pageFrom,
    int? pageTo,
    int? currentPage,
    WriteTransaction? transaction,
  }) {
    return _insertPlan(
      title: title,
      materialId: materialId,
      goalId: goalId,
      conversationId: conversationId,
      pageFrom: pageFrom,
      pageTo: pageTo,
      currentPage: currentPage,
      executor: writeExecutor(transaction, _db),
    );
  }

  Future<int> _insertPlan({
    required String title,
    required int? materialId,
    required int? goalId,
    required int? conversationId,
    required int? pageFrom,
    required int? pageTo,
    required int? currentPage,
    required RawExecutor executor,
  }) async {
    final text = title.trim();
    if (text.isEmpty) throw ArgumentError('学习计划的标题不能为空');
    final now = formatDateTime(_clock());
    return executor.writeGenerated(
      (db) => db.insertStudyPlan(
        materialId,
        goalId,
        conversationId,
        text,
        pageFrom,
        pageTo,
        currentPage,
        StudyPlanStatus.active.value,
        now,
      ),
    );
  }

  /// 在同一事务内创建学习计划及其全部步骤。
  Future<int> createWithDrafts({
    required String title,
    required List<StudyStepDraft> drafts,
    int? materialId,
    int? goalId,
    int? conversationId,
    int? pageFrom,
    int? pageTo,
    int? currentPage,
    WriteTransaction? transaction,
  }) async {
    final txn = writeExecutor(transaction, _db);
    final planId = await _insertPlan(
      title: title,
      materialId: materialId,
      goalId: goalId,
      conversationId: conversationId,
      pageFrom: pageFrom,
      pageTo: pageTo,
      currentPage: currentPage,
      executor: txn,
    );
    final now = formatDateTime(_clock());
    var seq = 1;
    for (final draft in drafts) {
      final stepTitle = draft.title.trim();
      if (stepTitle.isEmpty) continue;
      await txn.writeGenerated(
        (db) => db.insertStudyPlanStep(
          goalId,
          planId,
          seq++,
          stepTitle,
          draft.isPrerequisite
              ? '此前未接触的必要内容${draft.note == null ? '' : '：${draft.note}'}'
              : draft.note,
          draft.pageFrom,
          draft.pageTo,
          PlanItemStatus.todo.value,
          now,
        ),
      );
    }
    return planId;
  }

  /// 按顺序把草案写成学习事项；计划的材料、目标与来源讨论一并带上。
  Future<void> addDrafts(
    int planId,
    List<StudyStepDraft> drafts, {
    WriteTransaction? transaction,
  }) async {
    final plan = await byId(planId);
    if (plan == null) throw StateError('未找到这份学习计划');
    final now = formatDateTime(_clock());
    final txn = writeExecutor(transaction, _db);
    final lastSeq = await txn.selectGenerated(
      (db) => db.lastPlanStepSeq(planId).getSingleOrNull(),
    );
    var seq = (lastSeq ?? 0) + 1;
    for (final draft in drafts) {
      final title = draft.title.trim();
      if (title.isEmpty) continue;
      await txn.writeGenerated(
        (db) => db.insertStudyPlanStep(
          plan.goalId,
          planId,
          seq++,
          title,
          draft.isPrerequisite
              ? '此前未接触的必要内容${draft.note == null ? '' : '：${draft.note}'}'
              : draft.note,
          draft.pageFrom,
          draft.pageTo,
          PlanItemStatus.todo.value,
          now,
        ),
      );
    }
  }

  static StudyPlan _planOf(PlanRowsResult row) => StudyPlan(
    id: row.id,
    title: row.title,
    materialId: row.materialId,
    goalId: row.goalId,
    conversationId: row.conversationId,
    pageFrom: row.pageFrom,
    pageTo: row.pageTo,
    currentPage: row.currentPage,
    status: StudyPlanStatus.fromValue(row.status),
    materialTitle: row.materialTitle,
    materialIsDocx: isDocxFile(row.sourceFileName),
    stepsDone: row.stepsDone,
    stepsTotal: row.stepsTotal,
    nextStepTitle: row.nextStepTitle,
    createdAt: requiredDateTime(row.createdAt),
    updatedAt: requiredDateTime(row.updatedAt),
  );

  static PlanItem _stepOf(PlanStepsResult row) => _stepItem(
    id: row.id,
    goalId: row.goalId,
    conversationId: row.conversationId,
    studyPlanId: row.studyPlanId,
    seq: row.seq,
    title: row.title,
    note: row.note,
    pageFrom: row.pageFrom,
    pageTo: row.pageTo,
    sourceFileName: row.sourceFileName,
    dueAt: row.dueAt,
    estMinutes: row.estMinutes,
    priority: row.priority,
    status: row.status,
    source: row.source,
    completedAt: row.completedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  static PlanItem _stepOfForPlans(PlanStepsForPlansResult row) => _stepItem(
    id: row.id,
    goalId: row.goalId,
    conversationId: row.conversationId,
    studyPlanId: row.studyPlanId,
    seq: row.seq,
    title: row.title,
    note: row.note,
    pageFrom: row.pageFrom,
    pageTo: row.pageTo,
    sourceFileName: row.sourceFileName,
    dueAt: row.dueAt,
    estMinutes: row.estMinutes,
    priority: row.priority,
    status: row.status,
    source: row.source,
    completedAt: row.completedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  static PlanItem _stepItem({
    required int id,
    required int? goalId,
    required int? conversationId,
    required int? studyPlanId,
    required int? seq,
    required String title,
    required String? note,
    required int? pageFrom,
    required int? pageTo,
    required String? sourceFileName,
    required String? dueAt,
    required int? estMinutes,
    required int priority,
    required String status,
    required String source,
    required String? completedAt,
    required String createdAt,
    required String updatedAt,
  }) => PlanItem(
    id: id,
    goalId: goalId,
    conversationId: conversationId,
    studyPlanId: studyPlanId,
    seq: seq,
    title: title,
    note: note,
    pageFrom: pageFrom,
    pageTo: pageTo,
    materialIsDocx: isDocxFile(sourceFileName),
    dueAt: optionalDateTime(dueAt ?? ''),
    estMinutes: estMinutes,
    priority: priority,
    status: PlanItemStatus.fromValue(status),
    source: source,
    completedAt: optionalDateTime(completedAt ?? ''),
    createdAt: requiredDateTime(createdAt),
    updatedAt: requiredDateTime(updatedAt),
  );

  Future<StudyPlan?> byId(int id) async {
    final rows = await _planRows(id: id, rowLimit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 计划列表：进行中的排在前面，再按更新时间倒序。
  Future<List<StudyPlan>> list({bool openOnly = false}) async {
    return _planRows(openOnly: openOnly);
  }

  /// 最近推进过的进行中计划，只按更新时间倒序，取前 [limit] 份。
  ///
  /// 首页的“继续上次”把计划与讨论放在一起按时间排序，这里不能先按状态分组：
  /// 状态优先的顺序会让一份较早推进的计划挤掉另一份更近的，合并排序也就取不到
  /// 真正最近的几条。暂停的计划不进入首页，因此这里直接不读，不占名额。
  Future<List<StudyPlan>> listRecentlyAdvanced({int limit = 4}) async {
    if (limit <= 0) return const [];
    return _planRows(activeOnly: true, statusFirst: false, rowLimit: limit);
  }

  /// 一条语句覆盖按标识取、按状态筛与按时间排：不生效的条件由空参数关掉；
  /// `rowLimit` 传空表示不截断。
  Future<List<StudyPlan>> _planRows({
    int? id,
    bool openOnly = false,
    bool activeOnly = false,
    bool statusFirst = true,
    int? rowLimit,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .planRows(
            PlanItemStatus.done.value,
            id,
            openOnly ? 1 : 0,
            StudyPlanStatus.active.value,
            StudyPlanStatus.paused.value,
            activeOnly ? 1 : 0,
            statusFirst ? 1 : 0,
            rowLimit,
          )
          .get(),
    );
    return rows.map(_planOf).toList(growable: false);
  }

  /// 计划里的步骤，按顺序返回；每一步都是 `plan_item`。
  Future<List<PlanItem>> steps(int planId) async {
    final rows = await _db.selectGenerated((db) => db.planSteps(planId).get());
    return rows.map(_stepOf).toList(growable: false);
  }

  /// 多份计划的全部步骤，按计划与顺序返回；安排页的下一步与进度都从这里算。
  Future<List<PlanItem>> stepsForPlans(Iterable<int> planIds) async {
    final ids = {...planIds};
    if (ids.isEmpty) return const [];
    final rows = await _db.selectGenerated(
      (db) =>
          db.planStepsForPlans(jsonEncode(ids.toList(growable: false))).get(),
    );
    return rows.map(_stepOfForPlans).toList(growable: false);
  }

  Future<void> bindDiscussionToStep({
    required int planId,
    required int stepId,
    required int conversationId,
    WriteTransaction? transaction,
  }) async {
    final changed = await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.setStudyStepConversation(conversationId, stepId, planId),
    );
    if (changed != 1) throw StateError('学习步骤已变化，无法保存讨论入口');
  }

  /// 改一步的状态；进行中的步骤同时清掉同计划里其他进行中的步骤。
  Future<void> setStepStatus(
    int stepId,
    PlanItemStatus status, {
    int? expectedPlanId,
    WriteTransaction? transaction,
  }) async {
    final txn = writeExecutor(transaction, _db);
    final item = await txn.selectGenerated(
      (db) => db.itemPlan(stepId).getSingleOrNull(),
    );
    if (item == null) return;
    final planId = item.studyPlanId;
    if (planId == null) return;
    if (expectedPlanId != null && expectedPlanId != planId) {
      throw StateError('这一步不属于当前学习计划');
    }
    await _setItemStatus(txn, stepId, status, planId);
    await _recompute(txn, planId);
  }

  /// 所有事项状态入口共用计划步骤的唯一进行中规则。
  Future<void> setItemStatus(
    int itemId,
    PlanItemStatus status, {
    WriteTransaction? transaction,
  }) async {
    final txn = writeExecutor(transaction, _db);
    final item = await txn.selectGenerated(
      (db) => db.itemPlan(itemId).getSingleOrNull(),
    );
    if (item == null) return;
    final planId = item.studyPlanId;
    await _setItemStatus(txn, itemId, status, planId);
    if (planId != null) await _recompute(txn, planId);
  }

  Future<void> _setItemStatus(
    RawExecutor txn,
    int itemId,
    PlanItemStatus status,
    int? planId,
  ) async {
    final change = studyStepStatusChange(status, planId: planId);
    final now = formatDateTime(_clock());
    await txn.writeGenerated(
      (db) => db.setStudyStepStatus(
        change.status.value,
        change.status == PlanItemStatus.done ? now : null,
        now,
        itemId,
      ),
    );
    if (change.resetOtherActive) {
      await txn.writeGenerated(
        (db) => db.resetOtherActiveStudySteps(
          PlanItemStatus.todo.value,
          now,
          planId!,
          itemId,
          PlanItemStatus.doing.value,
        ),
      );
    }
    if (change.settleBlocks) {
      // 只有确实发生过学习的预约才记为结束：场次与这段时间有重叠才算完成。
      // 到过开始时间却没有场次的旧预约按取消处理，不再把没学的那几次写成完成。
      await txn.writeGenerated(
        (db) => db.settleBlocksOnStepDone(
          now,
          'done',
          'cancelled',
          itemId,
          'planned',
        ),
      );
    }
    if (change.cancelPlannedBlocks) {
      await txn.writeGenerated(
        (db) => db.cancelPlannedBlocksForItem(now, itemId),
      );
    }
  }

  Future<void> setStatus(
    int planId,
    StudyPlanStatus status, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.setStudyPlanStatus(status.value, stamp, planId),
    );
  }

  Future<void> _recompute(RawExecutor executor, int planId) async {
    final plan = await _plainPlan(planId, executor: executor);
    if (plan == null) return;
    final rows = await executor.selectGenerated(
      (db) => db.stepsOfPlan(planId).get(),
    );
    final allSteps = rows.map(_stepOfRow).toList(growable: false);
    final current = currentStudyStep(allSteps);
    final donePages = allSteps
        .where((step) => step.done && step.pageTo != null)
        .map((step) => step.pageTo!)
        .toList(growable: false);
    final currentPage =
        current?.pageFrom ??
        (donePages.isEmpty ? plan.currentPage : donePages.last);
    final finished = allSteps.isNotEmpty && allSteps.every((step) => step.done);
    final status = finished
        ? StudyPlanStatus.done
        : plan.done
        ? StudyPlanStatus.active
        : plan.status;
    if (currentPage == plan.currentPage && status == plan.status) return;
    final stamp = formatDateTime(_clock());
    await executor.writeGenerated(
      (db) => db.updateStudyPlanProgress(
        currentPage,
        status != plan.status ? status.value : null,
        stamp,
        planId,
      ),
    );
  }

  Future<StudyPlan?> _plainPlan(int id, {RawExecutor? executor}) async {
    final row = await (executor ?? _db).selectGenerated(
      (db) => db.studyPlanById(id).getSingleOrNull(),
    );
    return row == null ? null : _planOfRow(row);
  }

  /// 计划表的字段与领域模型同名，只补状态与时间解析。
  static StudyPlan _planOfRow(StudyPlanRow row) => StudyPlan(
    id: row.id,
    title: row.title,
    materialId: row.materialId,
    goalId: row.goalId,
    conversationId: row.conversationId,
    pageFrom: row.pageFrom,
    pageTo: row.pageTo,
    currentPage: row.currentPage,
    status: StudyPlanStatus.fromValue(row.status),
    createdAt: requiredDateTime(row.createdAt),
    updatedAt: requiredDateTime(row.updatedAt),
  );

  /// 步骤整行与其它查询挑的列不同名，走同一个 _stepItem 组装。
  static PlanItem _stepOfRow(PlanItemRow row) => _stepItem(
    id: row.id,
    goalId: row.goalId,
    conversationId: row.conversationId,
    studyPlanId: row.studyPlanId,
    seq: row.seq,
    title: row.title,
    note: row.note,
    pageFrom: row.pageFrom,
    pageTo: row.pageTo,
    sourceFileName: null,
    dueAt: row.dueAt,
    estMinutes: row.estMinutes,
    priority: row.priority,
    status: row.status,
    source: row.source,
    completedAt: row.completedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}
