import 'dart:convert';

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
    final rows = await _db.rawQuery(
      'SELECT * FROM learning_goal '
      'ORDER BY CASE status WHEN ? THEN 0 WHEN ? THEN 1 '
      'WHEN ? THEN 2 ELSE 3 END, id DESC',
      [
        LearningGoalStatus.active.code,
        LearningGoalStatus.paused.code,
        LearningGoalStatus.done.code,
      ],
    );
    return rows.map(LearningGoal.fromRow).toList(growable: false);
  }

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
    final where = <String>[];
    if (openOnly) where.add('p.status IN (?, ?)');
    if (onlyActiveGoals) where.add('(p.goal_id IS NULL OR g.status = ?)');
    final rows = await _db.rawQuery(
      '''
      SELECT $itemColumns FROM plan_item p
      LEFT JOIN learning_goal g ON g.id = p.goal_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY
        CASE p.status WHEN ? THEN 0 WHEN ? THEN 1
          WHEN ? THEN 2 WHEN ? THEN 3 ELSE 4 END,
        p.due_at IS NULL, p.due_at, p.id DESC
      ''',
      [
        if (openOnly) ...[PlanItemStatus.todo.code, PlanItemStatus.doing.code],
        if (onlyActiveGoals) LearningGoalStatus.active.code,
        PlanItemStatus.doing.code,
        PlanItemStatus.todo.code,
        PlanItemStatus.deferred.code,
        PlanItemStatus.done.code,
      ],
    );
    return rows.map(PlanItem.fromRow).toList(growable: false);
  }

  Future<PlanItem?> byId(int id, {WriteTransaction? transaction}) async {
    final rows = await writeExecutor(
      transaction,
      _db,
    ).rawQuery('SELECT $itemColumns FROM plan_item p WHERE p.id = ?', [id]);
    return rows.isEmpty ? null : PlanItem.fromRow(rows.first);
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
    final rows = await _db.query(
      'plan_item',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : PlanItem.fromRow(rows.first);
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

  /// 已完成事项按页读取，给安排页的“已完成”列表用。
  ///
  /// 已完成事项只增不减地积累，安排页默认不读；用户展开时按最近完成时间
  /// 从新到旧逐页读取，读取量只跟这一页有关。
  Future<List<PlanItem>> doneItems({int limit = 30, int offset = 0}) async {
    if (limit <= 0) return const [];
    final rows = await _db.rawQuery(
      'SELECT $itemColumns FROM plan_item p WHERE p.status = ? '
      'ORDER BY p.completed_at DESC, p.id DESC LIMIT ? OFFSET ?',
      [PlanItemStatus.done.code, limit, offset],
    );
    return rows.map(PlanItem.fromRow).toList(growable: false);
  }

  /// 已完成事项总数，用于“显示已完成（N）”与是否还有下一页。
  Future<int> countDone() async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM plan_item WHERE status = ?',
      [PlanItemStatus.done.code],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 按编号批量读取事项，按编号索引返回。
  ///
  /// 首页活动卡要在“正在进行”与“接下来”两条预约里各取一项，原先为此逐条
  /// 查询；这里用一次 `IN` 查询取回，读取次数与预约条数无关。
  Future<Map<int, PlanItem>> byIds(Iterable<int> ids) async {
    final keys = {...ids};
    if (keys.isEmpty) return const {};
    final placeholders = List.filled(keys.length, '?').join(', ');
    final rows = await _db.rawQuery(
      'SELECT $itemColumns FROM plan_item p WHERE p.id IN ($placeholders)',
      keys.toList(growable: false),
    );
    return {for (final row in rows) row['id']! as int: PlanItem.fromRow(row)};
  }

  Future<bool> hasScheduleOrSession(
    int itemId, {
    required WriteTransaction transaction,
  }) async {
    final rows = await writeExecutor(transaction, _db).rawQuery(
      '''
      SELECT 1 FROM schedule_block WHERE plan_item_id = ?
      UNION ALL
      SELECT 1 FROM study_session WHERE plan_item_id = ?
      LIMIT 1
      ''',
      [itemId, itemId],
    );
    return rows.isNotEmpty;
  }

  /// 待办里截止最近的一条；所属目标已暂停的事项不参与“现在”页推荐。
  Future<PlanItem?> nextDue() async {
    final rows = await _db.rawQuery(
      '''
      SELECT p.* FROM plan_item p
      LEFT JOIN learning_goal g ON g.id = p.goal_id
      WHERE p.status IN (?, ?)
        AND (p.goal_id IS NULL OR g.status = ?)
      ORDER BY p.due_at IS NULL, p.due_at, p.id
      LIMIT 1
      ''',
      [
        PlanItemStatus.todo.code,
        PlanItemStatus.doing.code,
        LearningGoalStatus.active.code,
      ],
    );
    return rows.isEmpty ? null : PlanItem.fromRow(rows.first);
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
