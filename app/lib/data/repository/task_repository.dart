import 'dart:convert';

import '../../domain/models/material.dart';
import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../../domain/rules/text.dart';
import '../db/write_transactions.dart';

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

  /// 六条查询挑的列相同，结果行按同一组字段还原成领域模型。
  static PlanItem _item(
    int id,
    int? goalId,
    int? conversationId,
    int? studyPlanId,
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
  ) => PlanItem(
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

  static PlanItem _itemOfItems(ItemsResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  static PlanItem _itemOfById(ItemByIdResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  static PlanItem _itemOfConversation(ItemByConversationResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  static PlanItem _itemOfDone(DoneItemsResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  static PlanItem _itemOfByIds(ItemsByIdsResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  static PlanItem _itemOfTitle(ItemByConversationAndTitleResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  static PlanItem _itemOfByStep(ItemByConversationAndStepResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );
  static PlanItem _itemOfNextDue(NextDueItemResult r) => _item(
    r.id,
    r.goalId,
    r.conversationId,
    r.studyPlanId,
    r.seq,
    r.title,
    r.note,
    r.pageFrom,
    r.pageTo,
    r.dueAt,
    r.estMinutes,
    r.priority,
    r.status,
    r.source,
    r.completedAt,
    r.createdAt,
    r.updatedAt,
    r.sourceFileName,
  );

  Future<LearningGoal?> goalById(
    int id, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final row = await executor.selectGenerated(
      (db) => db.goalById(id).getSingleOrNull(),
    );
    return row == null ? null : _goalOf(row);
  }

  /// 新建目标；已有效的其他目标保持原状。
  Future<int> createGoal({
    required String title,
    String? scopeText,
    DateTime? dueDate,
  }) async {
    final now = _clock();
    final stamp = formatDateTime(now);
    return _db.writeGenerated(
      (db) => db.insertLearningGoal(
        title.trim(),
        scopeText?.trim(),
        dueDate == null ? null : formatDate(dueDate),
        LearningGoalStatus.active.value,
        stamp,
      ),
    );
  }

  /// 暂停目标只改状态；相关未来安排与已完成记录保持原样。
  Future<void> pauseGoal(int id, {WriteTransaction? transaction}) =>
      _setGoalStatus(id, LearningGoalStatus.paused, transaction: transaction);

  Future<void> resumeGoal(int id, {WriteTransaction? transaction}) =>
      _setGoalStatus(id, LearningGoalStatus.active, transaction: transaction);

  Future<void> closeGoal(int id, {WriteTransaction? transaction}) =>
      _setGoalStatus(id, LearningGoalStatus.done, transaction: transaction);

  Future<void> _setGoalStatus(
    int id,
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

  Future<PlanItem?> byId(int id, {WriteTransaction? transaction}) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await executor.selectGenerated((db) => db.itemById(id).get());
    return rows.isEmpty ? null : _itemOfById(rows.first);
  }

  /// 把从这一步带入的讨论记回事项；已有讨论时不覆盖，避免把继续位置改乱。
  Future<void> bindConversation(
    int planItemId,
    int conversationId, {
    WriteTransaction? transaction,
  }) async {
    final stamp = formatDateTime(_clock());
    await writeExecutor(transaction, _db).writeGenerated(
      (db) => db.bindTaskConversation(conversationId, stamp, planItemId),
    );
  }

  /// 这条讨论绑定的学习步骤；普通入口从讨论开始作答时用它补上场次的事项。
  Future<PlanItem?> byConversation(int conversationId) async {
    final rows = await _db.selectGenerated(
      (db) => db.itemByConversation(conversationId).get(),
    );
    return rows.isEmpty ? null : _itemOfConversation(rows.first);
  }

  /// 同一条讨论里同一个建议编号对应的事项；重复请求据此返回原结果。
  Future<PlanItem?> byConversationAndStep(
    int conversationId,
    String stepId,
  ) async {
    final rows = await _db.selectGenerated(
      (db) => db.itemByConversationAndStep(conversationId, stepId).get(),
    );
    return rows.isEmpty ? null : _itemOfByStep(rows.first);
  }

  /// 从讨论里接受建议后按标题找回刚才建立的事项，供重复请求返回原结果。
  Future<PlanItem?> byConversationAndTitle(
    int conversationId,
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
  /// 首页活动卡要在“正在进行”与“接下来”两条预约里各取一项，原先为此逐条
  /// 查询；这里用一次 `IN` 查询取回，读取次数与预约条数无关。
  Future<Map<int, PlanItem>> byIds(Iterable<int> ids) async {
    final keys = {...ids};
    if (keys.isEmpty) return const {};
    final rows = await _db.selectGenerated(
      (db) => db.itemsByIds(jsonEncode(keys.toList(growable: false))).get(),
    );
    return {for (final row in rows) row.id: _itemOfByIds(row)};
  }

  Future<bool> hasScheduleOrSession(
    int itemId, {
    WriteTransaction? transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await executor.selectGenerated(
      (db) => db.itemHasScheduleOrSession(itemId).get(),
    );
    return rows.isNotEmpty;
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

  /// 新建事项只保留一段说明。
  Future<int> createItem({
    required String title,
    int? goalId,
    int? conversationId,
    String? note,
    DateTime? dueAt,
    int? estMinutes,
    String source = 'user',
    Map<String, Object?>? origin,
    WriteTransaction? transaction,
  }) async {
    final now = _clock();
    return writeExecutor(transaction, _db).writeGenerated(
      (db) => db.insertPlanItem(
        goalId,
        conversationId,
        title.trim(),
        nullableText(note),
        dueAt == null ? null : formatDateTime(dueAt),
        estMinutes,
        PlanItemStatus.todo.value,
        source,
        origin == null ? null : jsonEncode(origin),
        formatDateTime(now),
      ),
    );
  }

  /// 0 普通、1 优先、2 最高；容量不足时按它排序。
  Future<void> setPriority(
    int id,
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

  Future<void> deleteItem(int id) async {
    await _db.writeGenerated((db) => db.deletePlanItem(id));
  }
}
