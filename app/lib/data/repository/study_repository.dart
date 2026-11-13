import 'package:sqflite/sqflite.dart';

import '../../domain/models/study.dart';
import '../../domain/rules/time_format.dart';
import '../../domain/rules/time_policy.dart';
import '../db/write_transactions.dart';

/// 一次学习（01 `study_session`）：从搭子、题目或日程开始，多次尝试共用一个结果。
class StudyRepository {
  StudyRepository(this._db, {this._clock = systemClock});

  final Database _db;
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

  Future<StudySession?> openFor({
    int? planItemId,
    int? goalId,
    int? conversationId,
    WriteTransaction? transaction,
  }) async {
    final where = <String>['ended_at IS NULL'];
    final args = <Object?>[];
    if (conversationId != null) {
      where.add('conversation_id = ?');
      args.add(conversationId);
    } else {
      where.add('conversation_id IS NULL');
      if (planItemId != null) {
        where.add('plan_item_id = ?');
        args.add(planItemId);
      } else {
        where.add('plan_item_id IS NULL');
        if (goalId == null) {
          where.add('goal_id IS NULL');
        } else {
          where.add('goal_id = ?');
          args.add(goalId);
        }
      }
    }
    final rows = await writeExecutor(transaction, _db).query(
      'study_session',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : StudySession.fromRow(rows.first);
  }

  Future<StudySession?> byId(int id, {WriteTransaction? transaction}) async {
    final rows = await writeExecutor(
      transaction,
      _db,
    ).query('study_session', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : StudySession.fromRow(rows.first);
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
    final rows = await _db.query(
      'study_session',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(StudySession.fromRow).toList(growable: false);
  }

  /// 同一目标下已经结束的场次，按结束时间倒序；用于比较困难是否重复出现。
  ///
  /// [limit] 为空时返回这个目标的全部已结束场次，避免同一困难隔了很多次
  /// 学习再出现时被固定条数漏掉。
  Future<List<StudySession>> recentForGoal(
    int goalId, {
    int? limit = 20,
  }) async {
    final rows = await _db.query(
      'study_session',
      where: 'goal_id = ? AND ended_at IS NOT NULL',
      whereArgs: [goalId],
      orderBy: 'ended_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(StudySession.fromRow).toList(growable: false);
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
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _db.query(
      'study_session',
      where: 'plan_item_id IN ($placeholders) AND ended_at IS NOT NULL',
      whereArgs: ids,
      orderBy: 'ended_at ASC, id ASC',
    );
    final result = <int, StudySession>{};
    for (final row in rows) {
      final session = StudySession.fromRow(row);
      final planItemId = session.planItemId;
      if (planItemId != null) result[planItemId] = session;
    }
    return result;
  }
}
