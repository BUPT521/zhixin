import 'dart:convert';

import '../db/drift/app_database.dart';
import '../db/raw_executor.dart';

import '../../domain/models/study.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 一次学习（01 `study_session`）：从搭子、题目或日程开始，多次尝试共用一个结果。
class StudyRepository {
  StudyRepository(this._db, {this._clock = systemClock});

  final RawDatabase _db;
  final Clock _clock;

  Future<StudySession> start({
    int? goalId,
    int? planItemId,
    int? conversationId,
    WriteTransaction? transaction,
  }) async {
    final now = _clock();
    final id = await writeExecutor(transaction, _db).insert('study_session', {
      'goal_id': goalId,
      'plan_item_id': planItemId,
      'conversation_id': conversationId,
      'started_at': formatDateTime(now),
      'created_at': formatDateTime(now),
      'updated_at': formatDateTime(now),
    });
    return StudySession(
      id: id,
      goalId: goalId,
      planItemId: planItemId,
      conversationId: conversationId,
      startedAt: now,
    );
  }

  /// 生成查询挂在 drift 连接上；只读副本没有连接，遇到时说明用法错了。
  AppDatabase _connect([WriteTransaction? transaction]) {
    final executor = writeExecutor(transaction, _db);
    final connection = executor.driftConnection;
    if (connection is AppDatabase) return connection;
    throw StateError('该查询走 drift 生成代码，需要在主库连接上执行');
  }

  /// 场次表的字段与领域模型同名，只补时间解析。
  static StudySession _sessionOf(StudySessionRow row) => StudySession(
    id: row.id,
    goalId: row.goalId,
    planItemId: row.planItemId,
    conversationId: row.conversationId,
    summary: row.summary,
    outcome: row.outcome,
    startedAt: parseDateTime(row.startedAt),
    endedAt: DateTime.tryParse(row.endedAt ?? ''),
  );

  Future<StudySession?> openFor({
    int? goalId,
    int? planItemId,
    int? conversationId,
    WriteTransaction? transaction,
  }) async {
    final row = await _connect(transaction)
        .openStudySession(conversationId ?? 0, planItemId ?? 0, goalId ?? 0)
        .getSingleOrNull();
    return row == null ? null : _sessionOf(row);
  }

  Future<StudySession?> byId(int id, {WriteTransaction? transaction}) async {
    final row = await _connect(transaction)
        .studySessionById(id)
        .getSingleOrNull();
    return row == null ? null : _sessionOf(row);
  }

  Future<void> end(
    int id, {
    String? outcome,
    String? summary,
    WriteTransaction? transaction,
  }) async {
    final now = formatDateTime(_clock());
    await writeExecutor(transaction, _db).update(
      'study_session',
      {
        'outcome': outcome,
        'summary': summary?.trim(),
        'ended_at': now,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<StudySession>> recent({int limit = 10}) async {
    final rows = await _connect().recentStudySessions(limit).get();
    return rows.map(_sessionOf).toList(growable: false);
  }

  /// 同一目标下已经结束的场次，按结束时间倒序；用于比较困难是否重复出现。
  ///
  /// [limit] 为空时返回这个目标的全部已结束场次，避免同一困难隔了很多次
  /// 学习再出现时被固定条数漏掉。
  Future<List<StudySession>> recentForGoal(
    int goalId, {
    int? limit = 20,
  }) async {
    final rows = await _connect()
        .endedStudySessionsForGoal(goalId, limit ?? (1 << 30))
        .get();
    return rows.map(_sessionOf).toList(growable: false);
  }

  /// 每个学习步骤最近一次已经结束的场次，一次查询取回。
  ///
  /// 步骤卡用它显示完成时间、这次结果与困难摘要，不按步骤逐条查库；同一
  /// 步骤有多次学习时保留结束时间最晚的一条。
  Future<Map<int, StudySession>> latestEndedByPlanItem(
    Iterable<int> planItemIds,
  ) async {
    final ids = planItemIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};
    final rows = await _connect()
        .endedStudySessionsForPlanItems(jsonEncode(ids))
        .get();
    final result = <int, StudySession>{};
    for (final row in rows) {
      final session = _sessionOf(row);
      final planItemId = session.planItemId;
      if (planItemId != null) result[planItemId] = session;
    }
    return result;
  }
}
