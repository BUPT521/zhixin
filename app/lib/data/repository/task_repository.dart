import 'dart:convert';

import '../../domain/models/material.dart';
import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/text.dart';
import '../../domain/rules/uuid_v7.dart';
import '../db/write_transactions.dart';

/// 事项查询结果行的公共列：九条查询挑的列相同，映射按名字转交，不看位置。
///
/// 位置参数一旦同类型相邻（`goalId`、`conversationId`、`studyPlanId` 都是
/// `String?`），少写或多写一个参数编译器看不出来；具名记录把每一列写清楚。
typedef PlanItemColumns = ({
  String id,
  String? goalId,
  String? conversationId,
  String? studyPlanId,
  int? seq,
  String title,
  String? note,
  int? pageFrom,
  int? pageTo,
  String? dueAt,
  int? estMinutes,
  int priority,
  String status,
  String source,
  String? completedAt,
  String createdAt,
  String updatedAt,
  String? sourceFileName,
});

/// 目标与学习事项（01 `learning_goal` / `plan_item`）。
///
/// 多个目标可以同时有效；创建目标不归档其他目标。学习事项可以来自某次讨论，
/// 也可以没有目标归属。
class TaskRepository {
  static const itemColumns =
      'p.*, (SELECT m.source_file_name FROM study_plan sp '
      'JOIN material m ON m.id = sp.material_id '
      'WHERE sp.id = p.study_plan_id) AS source_file_name';

  TaskRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  /// 当前有效的全部目标；没有截止日期的排在后面。
  Future<List<LearningGoal>> activeGoals() async {
    final rows = await _db.selectGenerated(
      (db) => db.activeGoals(LearningGoalStatus.active.value).get(),
    );
    return rows.map(_goalOf).toList(growable: false);
  }

  /// 全部目标，当前有效的排在最前，其余按新建时间倒序。
  Future<List<LearningGoal>> goals() async {
    final rows = await _db.selectGenerated(
      (db) => db
          .goals(
            LearningGoalStatus.active.value,
            LearningGoalStatus.paused.value,
            LearningGoalStatus.done.value,
          )
          .get(),
    );
    return rows.map(_goalOf).toList(growable: false);
  }

  /// 目标表的字段与领域模型同名，只补状态与时间解析。
  static LearningGoal _goalOf(LearningGoalRow row) => LearningGoal(
    id: row.id,
    title: row.title,
    scopeText: row.scopeText,
    dueDate: row.dueDate,
    status: LearningGoalStatus.fromValue(row.status),
    createdAt: requiredDateTime(row.createdAt),
    updatedAt: requiredDateTime(row.updatedAt),
  );

  /// 九条查询挑的列相同，结果行按同一组字段还原成领域模型。
  static PlanItem _item(PlanItemColumns row) => PlanItem(
    id: row.id,
    goalId: row.goalId,
    conversationId: row.conversationId,
    studyPlanId: row.studyPlanId,
    seq: row.seq,
    title: row.title,
    note: row.note,
    pageFrom: row.pageFrom,
    pageTo: row.pageTo,
    materialIsDocx: isDocxFile(row.sourceFileName),
    dueAt: optionalDateTime(row.dueAt),
    estMinutes: row.estMinutes,
    priority: row.priority,
    status: PlanItemStatus.fromValue(row.status),
    source: PlanItemSource.fromValue(row.source),
    completedAt: optionalDateTime(row.completedAt),
    createdAt: requiredDateTime(row.createdAt),
    updatedAt: requiredDateTime(row.updatedAt),
  );

  static PlanItem _itemOfItems(ItemsResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfById(ItemByIdResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfConversation(ItemByConversationResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfDone(DoneItemsResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfByIds(ItemsByIdsResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfTitle(ItemByConversationAndTitleResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfByStep(ItemByConversationAndStepResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfNextDue(NextDueItemResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  static PlanItem _itemOfSearch(SearchPlanItemsResult r) => _item((
    id: r.id,
    goalId: r.goalId,
    conversationId: r.conversationId,
    studyPlanId: r.studyPlanId,
    seq: r.seq,
    title: r.title,
    note: r.note,
    pageFrom: r.pageFrom,
    pageTo: r.pageTo,
    dueAt: r.dueAt,
    estMinutes: r.estMinutes,
    priority: r.priority,
    status: r.status,
    source: r.source,
    completedAt: r.completedAt,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    sourceFileName: r.sourceFileName,
  ));

  Future<LearningGoal?> goalById(
    String id, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final row = await executor.selectGenerated(
      (db) => db.goalById(id).getSingleOrNull(),
    );
    return row == null ? null : _goalOf(row);
  }

  /// 新建目标；已有效的其他目标保持原状。
  Future<String> createGoal({
    required String title,
    String? scopeText,
    DateTime? dueDate,
    WriteTransaction? transaction,
  }) async {
    final now = _clock();
    final stamp = formatDateTime(now);
    final id = newUuidV7();
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertLearningGoal(
        id,
        title.trim(),
        scopeText?.trim(),
        dueDate == null ? null : formatDate(dueDate),
        LearningGoalStatus.active.value,
        stamp,
      ),
    );
    return id;
  }

  /// 暂停目标只更新目标状态。
  Future<void> pauseGoal(String id, {WriteTransaction? transaction}) =>
      _setGoalStatus(id, LearningGoalStatus.paused, transaction: transaction);

  Future<void> resumeGoal(String id, {WriteTransaction? transaction}) =>
      _setGoalStatus(id, LearningGoalStatus.active, transaction: transaction);

  Future<void> closeGoal(String id, {WriteTransaction? transaction}) =>
      _setGoalStatus(id, LearningGoalStatus.done, transaction: transaction);

  Future<void> _setGoalStatus(
    String id,
    LearningGoalStatus status, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.setLearningGoalStatus(status.value, stamp, id));
  }

  /// 学习事项。`onlyActiveGoals` 只保留无归属或所属目标仍在进行的事项，
  /// 用于“现在”页的推荐；计划页要看到全部，因此默认关闭。
  Future<List<PlanItem>> items({
    bool openOnly = false,
    bool onlyActiveGoals = false,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .items(
            openOnly ? 1 : 0,
            PlanItemStatus.todo.value,
            PlanItemStatus.doing.value,
            onlyActiveGoals ? 1 : 0,
            LearningGoalStatus.active.value,
            1,
            PlanItemStatus.deferred.value,
            PlanItemStatus.done.value,
          )
          .get(),
    );
    return rows.map(_itemOfItems).toList(growable: false);
  }

  Future<PlanItem?> byId(String id, {WriteTransaction? transaction}) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await executor.selectGenerated((db) => db.itemById(id).get());
    return rows.isEmpty ? null : _itemOfById(rows.first);
  }

  /// 把从这一步带入的讨论记回事项；已有讨论时不覆盖，避免把继续位置改乱。
  Future<void> bindConversation(
    String planItemId,
    String conversationId, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.bindTaskConversation(conversationId, stamp, planItemId),
    );
  }

  /// 这条讨论绑定的学习步骤；普通入口从讨论开始作答时用它补上场次的事项。
  Future<PlanItem?> byConversation(String conversationId) async {
    final rows = await _db.selectGenerated(
      (db) => db.itemByConversation(conversationId).get(),
    );
    return rows.isEmpty ? null : _itemOfConversation(rows.first);
  }

  /// 同一条讨论里同一个建议编号对应的事项；重复请求据此返回原结果。
  Future<PlanItem?> byConversationAndStep(
    String conversationId,
    String stepId,
  ) async {
    final rows = await _db.selectGenerated(
      (db) => db.itemByConversationAndStep(conversationId, stepId).get(),
    );
    return rows.isEmpty ? null : _itemOfByStep(rows.first);
  }

  /// 从讨论里接受建议后按标题找回刚才建立的事项，供重复请求返回原结果。
  Future<PlanItem?> byConversationAndTitle(
    String conversationId,
    String title,
  ) async {
    final row = await _db.selectGenerated(
      (db) => db
          .itemByConversationAndTitle(conversationId, title.trim())
          .getSingleOrNull(),
    );
    return row == null ? null : _itemOfTitle(row);
  }

  Future<List<PlanItem>> doneItems({int limit = 30, int offset = 0}) async {
    if (limit <= 0) return const [];
    final rows = await _db.selectGenerated(
      (db) => db.doneItems(PlanItemStatus.done.value, limit, offset).get(),
    );
    return rows.map(_itemOfDone).toList(growable: false);
  }

  /// 已完成事项总数，用于“显示已完成（N）”与是否还有下一页。
  Future<int> countDone() async {
    final rows = await _db.selectGenerated(
      (db) => db.countDoneItems(PlanItemStatus.done.value).get(),
    );
    return rows.isEmpty ? 0 : rows.first;
  }

  /// 按编号批量读取事项，按编号索引返回。
  ///
  /// 按编号批量读取事项。
  Future<Map<String, PlanItem>> byIds(Iterable<String> ids) async {
    final keys = {...ids};
    if (keys.isEmpty) return const {};
    final rows = await _db.selectGenerated(
      (db) => db.itemsByIds(jsonEncode(keys.toList(growable: false))).get(),
    );
    return {for (final row in rows) row.id: _itemOfByIds(row)};
  }

  /// 待办里截止最近的一条；所属目标已暂停的事项不参与“现在”页推荐。
  Future<PlanItem?> nextDue() async {
    final rows = await _db.selectGenerated(
      (db) => db
          .nextDueItem(
            PlanItemStatus.todo.value,
            PlanItemStatus.doing.value,
            LearningGoalStatus.active.value,
          )
          .get(),
    );
    return rows.isEmpty ? null : _itemOfNextDue(rows.first);
  }

  /// 安排查找的事项：目标、状态与截止日期在库里筛，关键词由应用层筛。
  ///
  /// 日期条件是自然日区间，截止时间为空的事项不进入带日期的结果；三个条件
  /// 都为空时返回全部事项，由调用方按关键词再筛一遍（docs/02 第 3.14 节）。
  Future<List<PlanItem>> searchItems({
    String? goalId,
    PlanItemStatus? status,
    DateTime? dayStart,
    DateTime? dayEnd,
  }) async {
    final rows = await _db.selectGenerated(
      (db) => db
          .searchPlanItems(
            goalId ?? '',
            status?.value ?? '',
            dayStart == null ? '' : formatDateTime(dayStart),
            dayEnd == null ? '' : formatDateTime(dayEnd),
          )
          .get(),
    );
    return rows.map(_itemOfSearch).toList(growable: false);
  }

  /// 新建事项只保留一段说明。
  Future<String> createItem({
    required String title,
    String? goalId,
    String? conversationId,
    String? note,
    DateTime? dueAt,
    int? estMinutes,
    PlanItemSource source = PlanItemSource.user,
    bool start = false,
    Map<String, Object?>? origin,
    WriteTransaction? transaction,
  }) async {
    final now = _clock();
    final id = newUuidV7();
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertPlanItem(
        id,
        goalId,
        conversationId,
        title.trim(),
        nullableText(note),
        dueAt == null ? null : formatDateTime(dueAt),
        estMinutes,
        (start ? PlanItemStatus.doing : PlanItemStatus.todo).value,
        source.value,
        origin == null ? null : jsonEncode(origin),
        formatDateTime(now),
      ),
    );
    return id;
  }

  /// 0 普通、1 优先、2 最高；首页推荐时按它排序。
  Future<void> setPriority(
    String id,
    int priority, {
    WriteTransaction? transaction,
  }) async {
    final value = priority.clamp(0, 2);
    final stamp = formatDateTime(_clock());
    await writeExecutor(
      transaction,
      _db,
    ).writeGenerated((db) => db.setPlanItemPriority(value, stamp, id));
  }
}
