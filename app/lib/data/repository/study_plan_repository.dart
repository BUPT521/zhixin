import 'dart:convert';

import '../../domain/models/material.dart';
import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/models/study_plan.dart';
import '../../domain/rules/study_plan_steps.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/uuid_v7.dart';
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

  Future<String> create({
    required String title,
    String? materialId,
    String? goalId,
    String? conversationId,
    int? pageFrom,
    int? pageTo,
    WriteTransaction? transaction,
  }) {
    return _insertPlan(
      title: title,
      materialId: materialId,
      goalId: goalId,
      conversationId: conversationId,
      pageFrom: pageFrom,
      pageTo: pageTo,
      executor: writeExecutor(transaction, _db),
    );
  }

  Future<String> _insertPlan({
    required String title,
    required String? materialId,
    required String? goalId,
    required String? conversationId,
    required int? pageFrom,
    required int? pageTo,
    required RawExecutor executor,
  }) async {
    final text = title.trim();
    if (text.isEmpty) throw ArgumentError('学习计划的标题不能为空');
    final now = formatDateTime(_clock());
    final id = newUuidV7();
    await executor.writeGenerated(
      (db) => db.insertStudyPlan(
        id,
        materialId,
        goalId,
        conversationId,
        text,
        pageFrom,
        pageTo,
        StudyPlanStatus.active.value,
        now,
      ),
    );
    return id;
  }

  /// 在同一事务内创建学习计划及其全部步骤。
  Future<String> createWithDrafts({
    required String title,
    required List<StudyStepDraft> drafts,
    String? materialId,
    String? goalId,
    String? conversationId,
    int? pageFrom,
    int? pageTo,
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
      executor: txn,
    );
    final now = formatDateTime(_clock());
    var seq = 1;
    for (final draft in drafts) {
      final stepTitle = draft.title.trim();
      if (stepTitle.isEmpty) continue;
      await txn.writeGenerated(
        (db) => db.insertStudyPlanStep(
          newUuidV7(),
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
    required String id,
    required String? goalId,
    required String? conversationId,
    required String? studyPlanId,
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
    source: PlanItemSource.fromValue(source),
    completedAt: optionalDateTime(completedAt ?? ''),
    createdAt: requiredDateTime(createdAt),
    updatedAt: requiredDateTime(updatedAt),
  );

  Future<StudyPlan?> byId(String id) async {
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
    String? id,
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
  Future<List<PlanItem>> steps(String planId) async {
    final rows = await _db.selectGenerated((db) => db.planSteps(planId).get());
    return rows.map(_stepOf).toList(growable: false);
  }

  /// 多份计划的全部步骤，按计划与顺序返回；安排页的下一步与进度都从这里算。
  Future<List<PlanItem>> stepsForPlans(Iterable<String> planIds) async {
    final ids = {...planIds};
    if (ids.isEmpty) return const [];
    final rows = await _db.selectGenerated(
      (db) =>
          db.planStepsForPlans(jsonEncode(ids.toList(growable: false))).get(),
    );
    return rows.map(_stepOfForPlans).toList(growable: false);
  }

  Future<void> bindDiscussionToStep({
    required String planId,
    required String stepId,
    required String conversationId,
    WriteTransaction? transaction,
  }) async {
    final changed = await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.setStudyStepConversation(conversationId, stepId, planId),
    );
    if (changed != 1) throw StateError('学习步骤已变化，无法保存讨论入口');
  }

  /// 改一步的状态；进行中的步骤同时清掉同计划里其他进行中的步骤。
  Future<void> setStepStatus(
    String stepId,
    PlanItemStatus status, {
    String? expectedPlanId,
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
    String itemId,
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
    String itemId,
    PlanItemStatus status,
    String? planId,
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
  }

  Future<void> setStatus(
    String planId,
    StudyPlanStatus status, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.setStudyPlanStatus(status.value, stamp, planId),
    );
  }

  /// 步骤变化之后重算计划状态。
  ///
  /// 当前页由步骤在读取时算出，这里不再把页码写回计划行（审查 S5）：完成一步
  /// 只更新计划的状态与更新时间，不再多改一次 `study_plan`。
  Future<void> _recompute(RawExecutor executor, String planId) async {
    final plan = await _plainPlan(planId, executor: executor);
    if (plan == null) return;
    final rows = await executor.selectGenerated(
      (db) => db.stepsOfPlan(planId).get(),
    );
    final allSteps = rows.map(_stepOfRow).toList(growable: false);
    final finished = allSteps.isNotEmpty && allSteps.every((step) => step.done);
    final status = finished
        ? StudyPlanStatus.done
        : plan.done
        ? StudyPlanStatus.active
        : plan.status;
    if (status == plan.status) return;
    await executor.writeGenerated(
      (db) =>
          db.setStudyPlanStatus(status.value, formatDateTime(_clock()), planId),
    );
  }

  Future<StudyPlan?> _plainPlan(String id, {RawExecutor? executor}) async {
    final rows = await (executor ?? _db).selectGenerated(
      (db) => db
          .planRows(
            PlanItemStatus.done.value,
            id,
            0,
            StudyPlanStatus.active.value,
            StudyPlanStatus.paused.value,
            0,
            1,
            1,
          )
          .get(),
    );
    return rows.isEmpty ? null : _planOf(rows.first);
  }

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
