import 'dart:convert';

import '../../domain/models/material.dart';
import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
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
    final rows = await _db.query(
      'learning_goal',
      where: 'status = ?',
      whereArgs: [LearningGoalStatus.active.code],
      orderBy: 'due_date IS NULL, due_date, id DESC',
    );
    return rows.map(LearningGoal.fromRow).toList(growable: false);
  }

  /// 全部目标，当前有效的排在最前，其余按新建时间倒序。
  Future<List<LearningGoal>> goals() async {
    final rows = await _connect()
        .goals(
          LearningGoalStatus.active.code,
          LearningGoalStatus.paused.code,
          LearningGoalStatus.done.code,
        )
        .get();
    return rows
        .map(
          (row) => LearningGoal(
            id: row.id,
            title: row.title,
            scopeText: row.scopeText,
            dueDate: row.dueDate,
            status: LearningGoalStatus.fromCode(row.status),
            createdAt: DateTime.tryParse(row.createdAt),
            updatedAt: DateTime.tryParse(row.updatedAt),
          ),
        )
        .toList(growable: false);
  }

  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  AppDatabase _connect([RawExecutor? executor]) {
    final connection = (executor ?? _db).driftConnection;
    if (connection is AppDatabase) return connection;
    throw StateError('该查询走 drift 生成代码，需要在主库连接上执行');
  }

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
    dueAt: DateTime.tryParse(dueAt ?? ''),
    estMinutes: estMinutes,
    priority: priority,
    status: PlanItemStatus.fromCode(status),
    source: source,
    completedAt: DateTime.tryParse(completedAt ?? ''),
    createdAt: DateTime.tryParse(createdAt),
    updatedAt: DateTime.tryParse(updatedAt),
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
    final rows = await writeExecutor(
      transaction,
      _db,
    ).query('learning_goal', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : LearningGoal.fromRow(rows.first);
  }

  /// 新建目标；已有效的其他目标保持原状。
  Future<int> createGoal({
    required String title,
    String? scopeText,
    DateTime? dueDate,
  }) async {
    final now = _clock();
    final stamp = formatDateTime(now);
    return _db.insert('learning_goal', {
      'title': title.trim(),
      'scope_text': scopeText?.trim(),
      'due_date': dueDate == null ? null : formatDate(dueDate),
      'status': LearningGoalStatus.active.code,
      'created_at': stamp,
      'updated_at': stamp,
    });
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
    await writeExecutor(transaction, _db).update(
      'learning_goal',
      {'status': status.code, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 学习事项。`onlyActiveGoals` 只保留无归属或所属目标仍在进行的事项，
  /// 用于“现在”页的推荐；计划页要看到全部，因此默认关闭。
  Future<List<PlanItem>> items({
    bool openOnly = false,
    bool onlyActiveGoals = false,
  }) async {
    final rows = await _connect()
        .items(
          openOnly ? 1 : 0,
          PlanItemStatus.todo.code,
          PlanItemStatus.doing.code,
          onlyActiveGoals ? 1 : 0,
          LearningGoalStatus.active.code,
          1,
          PlanItemStatus.deferred.code,
          PlanItemStatus.done.code,
        )
        .get();
    return rows.map(_itemOfItems).toList(growable: false);
  }

  Future<PlanItem?> byId(int id, {WriteTransaction? transaction}) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await _connect(executor).itemById(id).get();
    return rows.isEmpty ? null : _itemOfById(rows.first);
  }

  /// 把从这一步带入的讨论记回事项；已有讨论时不覆盖，避免把继续位置改乱。
  Future<void> bindConversation(
    int planItemId,
    int conversationId, {
    WriteTransaction? transaction,
  }) async {
    await writeExecutor(transaction, _db).update(
      'plan_item',
      {
        'conversation_id': conversationId,
        'updated_at': formatDateTime(_clock()),
      },
      where: 'id = ? AND conversation_id IS NULL',
      whereArgs: [planItemId],
    );
  }

  /// 这条讨论绑定的学习步骤；普通入口从讨论开始作答时用它补上场次的事项。
  Future<PlanItem?> byConversation(int conversationId) async {
    final rows = await _connect().itemByConversation(conversationId).get();
    return rows.isEmpty ? null : _itemOfConversation(rows.first);
  }

  /// 同一条讨论里同一个建议编号对应的事项；重复请求据此返回原结果。
  Future<PlanItem?> byConversationAndStep(
    int conversationId,
    String stepId,
  ) async {
    final rows = await _db.rawQuery(
      "SELECT * FROM plan_item WHERE conversation_id = ? "
      "AND json_extract(origin_json, '\$.step_id') = ? "
      "ORDER BY id DESC LIMIT 1",
      [conversationId, stepId],
    );
    return rows.isEmpty ? null : PlanItem.fromRow(rows.first);
  }

  /// 从讨论里接受建议后按标题找回刚才建立的事项，供重复请求返回原结果。
  Future<PlanItem?> byConversationAndTitle(
    int conversationId,
    String title,
  ) async {
    final rows = await _db.query(
      'plan_item',
      where: 'conversation_id = ? AND title = ?',
      whereArgs: [conversationId, title.trim()],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : PlanItem.fromRow(rows.first);
  }

  Future<List<PlanItem>> doneItems({int limit = 30, int offset = 0}) async {
    if (limit <= 0) return const [];
    final rows = await _connect()
        .doneItems(PlanItemStatus.done.code, limit, offset)
        .get();
    return rows.map(_itemOfDone).toList(growable: false);
  }

  /// 已完成事项总数，用于“显示已完成（N）”与是否还有下一页。
  Future<int> countDone() async {
    final rows = await _connect()
        .countDoneItems(PlanItemStatus.done.code)
        .get();
    return rows.isEmpty ? 0 : rows.first;
  }

  /// 按编号批量读取事项，按编号索引返回。
  ///
  /// 首页活动卡要在“正在进行”与“接下来”两条预约里各取一项，原先为此逐条
  /// 查询；这里用一次 `IN` 查询取回，读取次数与预约条数无关。
  Future<Map<int, PlanItem>> byIds(Iterable<int> ids) async {
    final keys = {...ids};
    if (keys.isEmpty) return const {};
    final rows = await _connect()
        .itemsByIds(jsonEncode(keys.toList(growable: false)))
        .get();
    return {for (final row in rows) row.id: _itemOfByIds(row)};
  }

  Future<bool> hasScheduleOrSession(
    int itemId, {
    required WriteTransaction transaction,
  }) async {
    final executor = writeExecutor(transaction, _db);
    final rows = await _connect(executor)
        .itemHasScheduleOrSession(itemId)
        .get();
    return rows.isNotEmpty;
  }

  /// 待办里截止最近的一条；所属目标已暂停的事项不参与“现在”页推荐。
  Future<PlanItem?> nextDue() async {
    final rows = await _connect()
        .nextDueItem(
          PlanItemStatus.todo.code,
          PlanItemStatus.doing.code,
          LearningGoalStatus.active.code,
        )
        .get();
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
    return writeExecutor(transaction, _db).insert('plan_item', {
      'goal_id': goalId,
      'conversation_id': conversationId,
      'title': title.trim(),
      'note': _clean(note),
      'due_at': dueAt == null ? null : formatDateTime(dueAt),
      'est_minutes': estMinutes,
      'status': PlanItemStatus.todo.code,
      'source': source,
      'origin_json': origin == null ? null : jsonEncode(origin),
      'created_at': formatDateTime(now),
      'updated_at': formatDateTime(now),
    });
  }

  /// 0 普通、1 优先、2 最高；容量不足时按它排序。
  Future<void> setPriority(int id, int priority) async {
    final value = priority.clamp(0, 2);
    await _db.update(
      'plan_item',
      {'priority': value, 'updated_at': formatDateTime(_clock())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteItem(int id) async {
    await _db.delete('plan_item', where: 'id = ?', whereArgs: [id]);
  }

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}
